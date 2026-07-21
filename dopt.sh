#!/usr/bin/env bash
# dopt - Directory Optional Package Manager engine for standalone Linux software.
# Author: Ominous-Josef
# Version: 1.0.1
# License: GPLv3
# Description: A lightweight, manifest-driven package manager for standalone Linux tarballs.

set -euo pipefail

BIN_LINK_DIR="/usr/local/bin"
DESKTOP_DIR="/usr/share/applications"

# Default flag parameters
MANIFEST=""
DOWNLOAD=false
CLEANUP=false
FORCE_INSTALL=false
SEARCH_DIR="."
FILE_PATH=""
CUSTOM_URL=""
RESTART_REQD=false

show_help() {
    echo "dopt - Dynamic Optional Package Manager"
    echo "Usage: sudo ./dopt -m <recipe.json> [options]"
    echo ""
    echo "Manifest (Optional):"
    echo "  -m, --manifest <json>   The application manifest recipe configuration file"
    echo "  -a, --app-id <id>       Provide App ID directly if not using a manifest"
    echo ""
    echo "Deployment Targets (Choose one):"
    echo "  -d, --download          Download using the manifest's default server endpoint"
    echo "  -u, --url <url>         Download using a specific direct link override"
    echo "  -f, --file <path>       Directly deploy from a local archive package file"
    echo "  -p, --path <dir>        Scan a specific directory folder for a matching local archive"
    echo ""
    echo "Modifiers:"
    echo "  -c, --cleanup           Delete downloaded installer archive after a successful setup"
    echo "  -i, --install           Force run a fresh setup without checking prompts"
    echo "  -h, --help              Show this help menu"
}


# 1. Parse command-line inputs
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--manifest) MANIFEST="$2"; shift 2 ;;
        -a|--app-id)   APP_ID_CLI="$2"; shift 2 ;;
        -d|--download) DOWNLOAD=true; shift ;;
        -c|--cleanup)  CLEANUP=true; shift ;;
        -i|--install)  FORCE_INSTALL=true; shift ;;
        -u|--url)      DOWNLOAD=true; CUSTOM_URL="$2"; shift 2 ;;
        -f|--file)     FILE_PATH="$2"; shift 2 ;;
        -p|--path)     SEARCH_DIR="$2"; shift 2 ;;
        -h|--help)     show_help; exit 0 ;;
        *) echo "[-] Unknown option: $1" >&2; show_help; exit 1 ;;
    esac
done

if [[ -n "$MANIFEST" ]]; then
    # Verify JSON parser dependencies exist on host
    if ! command -v jq >/dev/null 2>&1; then
        echo "[-] Error: 'jq' utility is required when using a manifest. Please run: sudo dnf install jq" >&2
        exit 1
    fi

    if [[ ! -f "$MANIFEST" ]]; then
        echo "[-] Error: Manifest file not found: $MANIFEST" >&2
        exit 1
    fi
fi

# 2. Secure environment validation hooks
if [[ $EUID -ne 0 ]]; then
   echo "[-] Error: dopt engine modifications require root context. Re-run command using sudo." >&2
   exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# 3. Resolve App ID
if [[ -n "$MANIFEST" && -f "$MANIFEST" ]]; then
    APP_ID=$(jq -r '.app_id' "$MANIFEST")
else
    APP_ID="${APP_ID_CLI:-}"
    if [[ -z "$APP_ID" ]]; then
        echo "[*] No manifest provided. Using interactive setup..."
        read -r -p "[?] Enter App ID (e.g. com.example.app): " APP_ID
    fi
    [[ -z "$APP_ID" ]] && { echo "[-] Error: App ID is required."; exit 1; }
fi

# Extract legacy state for auto-population and cleanup
DEF_APP_NAME=""
DEF_SYMLINK_NAME=""
DEF_CLI_ANS=""
DEF_BINARY_PATTERN=""
DEF_ICON_MANIFEST=""
LEGACY_DESKTOP_FILE=""

if [[ -d "/opt/$APP_ID" ]]; then
    DESKTOP_SEARCH_PATHS=(
        "/usr/share/applications"
        "/usr/local/share/applications"
        "$USER_HOME/.local/share/applications"
        "/opt/$APP_ID"
    )
    for dp in "${DESKTOP_SEARCH_PATHS[@]}"; do
        if [[ -f "$dp/${APP_ID}.desktop" ]]; then
            EXEC_VAL=$(grep "^Exec=" "$dp/${APP_ID}.desktop" | cut -d= -f2- | awk '{print $1}' || true)
            if [[ "$EXEC_VAL" == "/usr/local/bin/"* || "$EXEC_VAL" == "/opt/"* ]]; then
                LEGACY_DESKTOP_FILE="$dp/${APP_ID}.desktop"
                break
            fi
        fi
    done

    if [[ -n "$LEGACY_DESKTOP_FILE" ]]; then
        DEF_APP_NAME=$(grep "^Name=" "$LEGACY_DESKTOP_FILE" | cut -d= -f2- || true)
        DEF_BIN_LINK=$(grep "^Exec=" "$LEGACY_DESKTOP_FILE" | cut -d= -f2- | awk '{print $1}' || true)
        DEF_SYMLINK_NAME=$(basename "$DEF_BIN_LINK" || true)
        DEF_CLI_ANS="n"
        
        if [[ -L "$DEF_BIN_LINK" ]]; then
            REAL_BIN=$(readlink -f "$DEF_BIN_LINK" 2>/dev/null || true)
            [[ -n "$REAL_BIN" ]] && DEF_BINARY_PATTERN=$(basename "$REAL_BIN")
        fi
        
        DEF_ICON_FULL=$(grep "^Icon=" "$LEGACY_DESKTOP_FILE" | cut -d= -f2- || true)
        DEF_ICON_MANIFEST=$(basename "$DEF_ICON_FULL" || true)
    else
        EXISTING_LINK=$(find /usr/local/bin -maxdepth 1 -type l -lname "/opt/$APP_ID/*" | head -n 1 2>/dev/null || true)
        if [[ -n "$EXISTING_LINK" ]]; then
            DEF_SYMLINK_NAME=$(basename "$EXISTING_LINK")
            DEF_CLI_ANS="y"
            REAL_BIN=$(readlink -f "$EXISTING_LINK" 2>/dev/null || true)
            [[ -n "$REAL_BIN" ]] && DEF_BINARY_PATTERN=$(basename "$REAL_BIN")
        fi
    fi
fi

# Ingest and extract remaining values
if [[ -n "$MANIFEST" && -f "$MANIFEST" ]]; then
    APP_NAME=$(jq -r '.name' "$MANIFEST")
    APP_COMMENT=$(jq -r '.comment' "$MANIFEST")
    DEFAULT_INSTALL_DIR=$(jq -r '.default_install_dir' "$MANIFEST")
    BINARY_PATTERN=$(jq -r '.binary_pattern' "$MANIFEST")
    BINARY_PATH=$(jq -r '.binary_path' "$MANIFEST")
    ICON_PATH_MANIFEST=$(jq -r '.icon_path' "$MANIFEST")
    CLI_ONLY=$(jq -r '.cli_only' "$MANIFEST")
    SYMLINK_NAME=$(jq -r '.symlink_as' "$MANIFEST")
    APP_CATEGORIES=$(jq -r '.categories' "$MANIFEST")
    EXEC_FLAGS=$(jq -r '.exec_flags' "$MANIFEST")
else
    [[ -d "/opt/$APP_ID" ]] && echo "[*] Existing installation detected. Auto-populating defaults..."
    
    read -r -p "[?] Enter Application Name [${DEF_APP_NAME:-$APP_ID}]: " APP_NAME
    APP_NAME=${APP_NAME:-${DEF_APP_NAME:-$APP_ID}}
    
    read -r -p "[?] Enter executable symlink name [${DEF_SYMLINK_NAME:-$APP_ID}]: " SYMLINK_NAME
    SYMLINK_NAME=${SYMLINK_NAME:-${DEF_SYMLINK_NAME:-$APP_ID}}
    
    cli_prompt_def="[y/N]"
    [[ "${DEF_CLI_ANS,,}" == "y" ]] && cli_prompt_def="[Y/n]"
    read -r -p "[?] Is this a CLI-only application? $cli_prompt_def: " cli_ans
    cli_ans=${cli_ans:-${DEF_CLI_ANS:-n}}
    if [[ "${cli_ans,,}" =~ ^(yes|y) ]]; then
        CLI_ONLY="true"
    else
        CLI_ONLY="false"
    fi
    
    APP_COMMENT=""
    DEFAULT_INSTALL_DIR="/opt/$APP_ID"
    
    read -r -p "[?] Enter target binary name to link [${DEF_BINARY_PATTERN:-$SYMLINK_NAME}]: " BINARY_PATTERN
    BINARY_PATTERN=${BINARY_PATTERN:-${DEF_BINARY_PATTERN:-$SYMLINK_NAME}}
    BINARY_PATH=""
    
    icon_prompt_def="(leave blank to auto-detect)"
    [[ -n "$DEF_ICON_MANIFEST" ]] && icon_prompt_def="[$DEF_ICON_MANIFEST]"
    read -r -p "[?] Enter icon file path/name $icon_prompt_def: " ICON_PATH_MANIFEST
    ICON_PATH_MANIFEST=${ICON_PATH_MANIFEST:-$DEF_ICON_MANIFEST}
    
    APP_CATEGORIES="Utility;"
    EXEC_FLAGS=""
fi

# Input Sanitization
if [[ "$APP_ID" == *"/"* || "$APP_ID" == *".."* || "$SYMLINK_NAME" == *"/"* || "$SYMLINK_NAME" == *".."* ]]; then
    echo "[-] CRITICAL: Security abort. APP_ID and SYMLINK_NAME cannot contain path traversal characters (/, ..)." >&2
    exit 1
fi

BIN_LINK="$BIN_LINK_DIR/$SYMLINK_NAME"
INSTALL_DIR=""

# 4. Resolve active system path bindings
echo "[*] Auditing environment path structures for $APP_NAME..."
EXISTING_BIN=$(sudo -u "$REAL_USER" which "$SYMLINK_NAME" 2>/dev/null || true)

if [[ -f "$BIN_LINK" ]]; then
    INSTALL_DIR=$(dirname "$(readlink -f "$BIN_LINK")")
    # Adjust install dir upward if it points deep into a nested binary folder
    if [[ -n "$BINARY_PATH" && "$BINARY_PATH" != "null" ]]; then
        DEPTH=$(echo "$BINARY_PATH" | tr -cd '/' | wc -c)
        for ((i=0; i<=DEPTH; i++)); do INSTALL_DIR=$(dirname "$INSTALL_DIR"); done
    fi
    echo "[+] Map match: Found existing installation via symlink at $INSTALL_DIR"
elif [[ -n "$EXISTING_BIN" ]]; then
    INSTALL_DIR=$(dirname "$(readlink -f "$EXISTING_BIN")")
    if [[ -n "$BINARY_PATH" && "$BINARY_PATH" != "null" ]]; then
        DEPTH=$(echo "$BINARY_PATH" | tr -cd '/' | wc -c)
        for ((i=0; i<=DEPTH; i++)); do INSTALL_DIR=$(dirname "$INSTALL_DIR"); done
    fi
    echo "[+] Map match: Found existing installation via environment PATH at $INSTALL_DIR"
else
    INSTALL_DIR="$DEFAULT_INSTALL_DIR"
    if [ "$FORCE_INSTALL" = false ]; then
        echo ""
        read -r -p "[?] No version found. Perform a clean installation of $APP_NAME at $INSTALL_DIR? [Y/n]: " inst_res
        if [[ "${inst_res,,}" =~ ^(no|n) ]]; then
            echo "[-] Deployment aborted."
            exit 0
        fi
    fi
fi

# 5. Target Architecture Resolution and Source Acquisition
TMP_DIR=$(mktemp -d -t dopt-workspace-XXXXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
    x86_64)  ARCH_KEY="default_url_x64" ;;
    aarch64) ARCH_KEY="default_url_arm64" ;;
    *) echo "[-] Error: Platform processor architecture ($ARCH_RAW) unsupported." >&2; exit 1 ;;
esac

if [ "$DOWNLOAD" = true ]; then
    if [[ -n "$CUSTOM_URL" ]]; then
        DOWNLOAD_URL="$CUSTOM_URL"
    elif [[ -n "$MANIFEST" && -f "$MANIFEST" ]]; then
        DOWNLOAD_URL=$(jq -r --arg key "$ARCH_KEY" '.[$key]' "$MANIFEST")
    else
        DOWNLOAD_URL=""
    fi
    
    if [[ -z "$DOWNLOAD_URL" || "$DOWNLOAD_URL" == "null" ]]; then
        echo "[-] Error: No download URL provided. Use -u <url> if not using a manifest." >&2
        exit 1
    fi
    
    TARBALL="$TMP_DIR/source_package.tar.gz"
    echo "[*] Pulling network distribution payloads from endpoint..."
    if ! curl -fL -o "$TARBALL" "$DOWNLOAD_URL"; then
        echo "[-] Error: Download gateway failed. Verify network routing or destination URL." >&2
        exit 1
    fi
elif [[ -n "$FILE_PATH" ]]; then
    [[ "$FILE_PATH" == "~"* ]] && FILE_PATH="${FILE_PATH/\~/$USER_HOME}"
    if [[ ! -f "$FILE_PATH" ]]; then echo "[-] Path fault: Target file missing: $FILE_PATH" >&2; exit 1; fi
    TARBALL="$FILE_PATH"
else
    [[ "$SEARCH_DIR" == "~"* ]] && SEARCH_DIR="${SEARCH_DIR/\~/$USER_HOME}"
    echo "[*] Scanning directories under '$SEARCH_DIR' for updates..."
    LATEST_TARBALL=$(ls -t -- "$SEARCH_DIR"/*"${APP_ID}"*.tar.gz 2>/dev/null | head -n 1 || true)
    if [[ -z "$LATEST_TARBALL" ]]; then
        echo "[-] Archive fault: No deployment packages matching *${APP_ID}*.tar.gz found." >&2; exit 1
    fi
    TARBALL="$LATEST_TARBALL"
fi

# 6. Unpack and Parse Sandbox Interior
echo "[*] Extracting execution code assets..."
tar -xzf "$TARBALL" -C "$TMP_DIR"

EXTRACTED_FOLDER=$(find "$TMP_DIR" -mindepth 1 -maxdepth 2 -type d -iname "*${APP_ID}*" | head -n 1)
[[ -z "$EXTRACTED_FOLDER" ]] && EXTRACTED_FOLDER=$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[[ -z "$EXTRACTED_FOLDER" ]] && EXTRACTED_FOLDER="$TMP_DIR"

# Dynamic nested folder bypass check
if [[ -n "$BINARY_PATH" && "$BINARY_PATH" != "null" ]]; then
    LOCAL_BIN="$EXTRACTED_FOLDER/$BINARY_PATH"
else
    LOCAL_BIN=$(find "$EXTRACTED_FOLDER" -maxdepth 1 -type f -iname "$BINARY_PATTERN" | head -n 1)
    [[ -z "$LOCAL_BIN" ]] && LOCAL_BIN=$(find "$EXTRACTED_FOLDER" -maxdepth 1 -type f -executable ! -name "chrome-sandbox" ! -name "crashpad_handler" | head -n 1)
fi

if [[ -n "$LOCAL_BIN" && -f "$LOCAL_BIN" ]]; then
    RUNNING_BIN_NAME=$(basename "$LOCAL_BIN")
    # Escape special regex characters to prevent regex injection attacks via pgrep/pkill
    ESCAPED_BIN_NAME=$(echo "$RUNNING_BIN_NAME" | sed 's/[^a-zA-Z0-9_-]/\\&/g')
    
    if pgrep -u "$REAL_USER" -f "$ESCAPED_BIN_NAME" > /dev/null 2>&1; then
        if [ "$FORCE_INSTALL" = true ]; then
            echo -e "\n[!] Warning: Forced installation active. Automatically terminating active processes for update..."
            pkill -u "$REAL_USER" -f "$ESCAPED_BIN_NAME" || true; sleep 1.5
            pkill -9 -u "$REAL_USER" -f "$ESCAPED_BIN_NAME" || true
            if [[ "$CLI_ONLY" != "true" ]]; then RESTART_REQD=true; fi
        else
            echo -e "\n[!] Active Process Block: $APP_NAME is currently running."
            read -r -p "[?] Kill process to deploy update? [Y/n]: " run_res
            if [[ ! "${run_res,,}" =~ ^(no|n) ]]; then
                pkill -u "$REAL_USER" -f "$ESCAPED_BIN_NAME" || true; sleep 1.5
                pkill -9 -u "$REAL_USER" -f "$ESCAPED_BIN_NAME" || true
                if [[ "$CLI_ONLY" != "true" ]]; then RESTART_REQD=true; fi
            else
                echo "[-] Update cycle canceled to keep app active."
                exit 0
            fi
        fi
    fi
fi

# 7. File Erasure and Allocation
INSTALL_DIR=$(readlink -m "$INSTALL_DIR")
SAFE_DIRS=("/" "/usr" "/bin" "/etc" "/var" "/opt" "/home" "/usr/local" "/usr/share" "/usr/local/bin")
for safe_dir in "${SAFE_DIRS[@]}"; do
    if [[ "$INSTALL_DIR" == "$safe_dir" ]]; then
        echo "[-] CRITICAL: Safety abort. Attempted to delete system directory: $INSTALL_DIR" >&2
        exit 1
    fi
done

echo "[*] Deep cleaning legacy directory mappings to clear stale libraries..."
rm -rf -- "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

echo "[*] Synchronizing updated frameworks into installation path..."
cp -R "$EXTRACTED_FOLDER"/. "$INSTALL_DIR/"

if [[ -n "$BINARY_PATH" && "$BINARY_PATH" != "null" ]]; then
    REAL_BINARY="$INSTALL_DIR/$BINARY_PATH"
else
    REAL_BINARY=$(find "$INSTALL_DIR" -maxdepth 1 -type f -iname "$BINARY_PATTERN" | head -n 1)
    [[ -z "$REAL_BINARY" ]] && REAL_BINARY=$(find "$INSTALL_DIR" -maxdepth 1 -type f -executable ! -name "chrome-sandbox" ! -name "crashpad_handler" | head -n 1)
fi

if [[ -z "$REAL_BINARY" || ! -f "$REAL_BINARY" ]]; then
    echo "[-] Critical Error: Execution file vector verification failed inside installation target." >&2
    exit 1
fi

chmod +x "$REAL_BINARY"
ln -sf "$REAL_BINARY" "$BIN_LINK"

# 8. Dynamic Linux Desktop Icon Integration Layout
if [[ "$CLI_ONLY" != "true" ]]; then
    echo "[*] Scanning workspace assets for Application Desktop Graphics..."
    ICON_PATH=""
    
    if [[ -n "${ICON_PATH_MANIFEST:-}" && "$ICON_PATH_MANIFEST" != "null" ]]; then
        if [[ -f "$INSTALL_DIR/$ICON_PATH_MANIFEST" ]]; then
            ICON_PATH="$INSTALL_DIR/$ICON_PATH_MANIFEST"
        else
            ICON_PATH=$(find "$INSTALL_DIR" -type f -iname "$ICON_PATH_MANIFEST" | head -n 1 || true)
        fi
    fi

    if [[ -z "$ICON_PATH" ]]; then
        ICON_PATH=$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 8 -type f \( -name "icon.png" -o -name "icon.svg" -o -name "${APP_ID}.png" -o -name "${APP_ID}.svg" -o -name "${SYMLINK_NAME}.png" -o -name "${SYMLINK_NAME}.svg" \) | head -n 1 || true)
    fi
    
    if [[ -z "$ICON_PATH" ]]; then
        # Define noisy directories to ignore during fallback search
        IGNORE_ICON_DIRS=("node_modules" ".*" "locales" "test*")
        
        # Dynamically build the find exclusion arguments
        FIND_PRUNE_ARGS=("-name" "${IGNORE_ICON_DIRS[0]}")
        for dir in "${IGNORE_ICON_DIRS[@]:1}"; do
            FIND_PRUNE_ARGS+=("-o" "-name" "$dir")
        done

        ICON_PATH=$(find "$INSTALL_DIR" -maxdepth 5 -type d \( "${FIND_PRUNE_ARGS[@]}" \) -prune -o -type f \( -name "*.png" -o -name "*.svg" \) -print | head -n 1 || true)
    fi

    DESKTOP_FILE="$DESKTOP_DIR/${APP_ID}.desktop"
    if [[ -n "${LEGACY_DESKTOP_FILE:-}" && "$LEGACY_DESKTOP_FILE" != "$DESKTOP_FILE" ]]; then
        echo "[*] Removing legacy desktop integration at $LEGACY_DESKTOP_FILE..."
        rm -f "$LEGACY_DESKTOP_FILE"
    fi
    echo "[*] Injecting desktop menu shell reference configuration at $DESKTOP_FILE..."

    cat << EOF > "$DESKTOP_FILE"
[Desktop Entry]
Version=1.0
Type=Application
Name=${APP_NAME}
Comment=${APP_COMMENT}
Exec=${BIN_LINK}${EXEC_FLAGS:+ $EXEC_FLAGS}
Icon=${ICON_PATH:-system-run}
Terminal=false
Categories=${APP_CATEGORIES:-Utility;}
StartupWMClass=$(basename "$REAL_BINARY")
EOF
    echo "[+] Native Desktop integration verified."
else
    echo "[*] App designated as CLI-only. Bypassing desktop shortcut layer."
fi

# 9. Post-Execution cleanup hooks
if [ "$DOWNLOAD" = true ]; then
    if [ "$CLEANUP" = true ]; then
        echo "[*] Removing compressed remote runtime package artifacts..."
    else
        URL_FILE_NAME=$(basename "$DOWNLOAD_URL" | sed 's/%20/ /g')
        [[ "$URL_FILE_NAME" == "download"* || -z "$URL_FILE_NAME" ]] && URL_FILE_NAME="${APP_ID}-linux.tar.gz"
        OUTPUT_DEST="$(pwd)/$URL_FILE_NAME"
        mv -f -- "$TARBALL" "$OUTPUT_DEST"
        [[ -n "${SUDO_USER:-}" ]] && chown -- "${SUDO_USER}:" "$OUTPUT_DEST"
        echo "[i] Local installation backup kept at: $OUTPUT_DEST"
    fi
fi

# 10. Environment variables reload check for UI relaunch mapping
if [[ "$CLI_ONLY" != "true" ]]; then
    if [ "$FORCE_INSTALL" = true ]; then
        if [ "$RESTART_REQD" = true ]; then
            echo "[*] Auto-relaunching application window environment..."
            sudo -u "$REAL_USER" env \
                DISPLAY="${DISPLAY:-:0}" \
                WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
                XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" \
                nohup "$BIN_LINK" > /dev/null 2>&1 &
            echo "[+] Application successfully brought back online."
        fi
    else
        echo ""
        read -r -p "[?] Deployment complete. Would you like to launch $APP_NAME now? [Y/n]: " launch_ans
        if [[ ! "${launch_ans,,}" =~ ^(no|n) ]]; then
            echo "[*] Launching application..."
            sudo -u "$REAL_USER" env \
                DISPLAY="${DISPLAY:-:0}" \
                WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
                XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" \
                nohup "$BIN_LINK" > /dev/null 2>&1 &
            echo "[+] Application successfully launched."
        fi
    fi
fi

echo -e "\n[+] Success! $APP_NAME has been deployed via dopt."