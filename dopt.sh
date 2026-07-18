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
    echo "Required:"
    echo "  -m, --manifest <json>   The application manifest recipe configuration file"
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

# 1. Verify JSON parser dependencies exist on host
if ! command -v jq >/dev/null 2>&1; then
    echo "[-] Error: 'jq' utility is missing. Please run: sudo dnf install jq" >&2
    exit 1
fi

# 2. Parse command-line inputs
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--manifest) MANIFEST="$2"; shift 2 ;;
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

if [[ -z "$MANIFEST" || ! -f "$MANIFEST" ]]; then
    echo "[-] Error: A valid application manifest file path is required (-m / --manifest)." >&2
    exit 1
fi

# 3. Secure environment validation hooks
if [[ $EUID -ne 0 ]]; then
   echo "[-] Error: dopt engine modifications require root context. Re-run command using sudo." >&2
   exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
USER_HOME=$(eval echo "~$REAL_USER")

# 4. Ingest and extract values out of the Manifest Recipe
APP_ID=$(jq -r '.app_id' "$MANIFEST")
APP_NAME=$(jq -r '.name' "$MANIFEST")
APP_COMMENT=$(jq -r '.comment' "$MANIFEST")
DEFAULT_INSTALL_DIR=$(jq -r '.default_install_dir' "$MANIFEST")
BINARY_PATTERN=$(jq -r '.binary_pattern' "$MANIFEST")
BINARY_PATH=$(jq -r '.binary_path' "$MANIFEST")
CLI_ONLY=$(jq -r '.cli_only' "$MANIFEST")
SYMLINK_NAME=$(jq -r '.symlink_as' "$MANIFEST")
APP_CATEGORIES=$(jq -r '.categories' "$MANIFEST")
EXEC_FLAGS=$(jq -r '.exec_flags' "$MANIFEST")

BIN_LINK="$BIN_LINK_DIR/$SYMLINK_NAME"
INSTALL_DIR=""

# 5. Resolve active system path bindings
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

# 6. Target Architecture Resolution and Source Acquisition
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
    else
        DOWNLOAD_URL=$(jq -r --arg key "$ARCH_KEY" '.[$key]' "$MANIFEST")
    fi
    
    if [[ -z "$DOWNLOAD_URL" || "$DOWNLOAD_URL" == "null" ]]; then
        echo "[-] Error: No default mirror link provided for this architecture layout in manifest." >&2
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
    LATEST_TARBALL=$(ls -t "$SEARCH_DIR"/*"${APP_ID}"*.tar.gz 2>/dev/null | head -n 1 || true)
    if [[ -z "$LATEST_TARBALL" ]]; then
        echo "[-] Archive fault: No deployment packages matching *${APP_ID}*.tar.gz found." >&2; exit 1
    fi
    TARBALL="$LATEST_TARBALL"
fi

# 7. Unpack and Parse Sandbox Interior
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
    [[ -z "$LOCAL_BIN" ]] && LOCAL_BIN=$(find "$EXTRACTED_FOLDER" -maxdepth 1 -type f -executable | head -n 1)
fi

if [[ -n "$LOCAL_BIN" && -f "$LOCAL_BIN" ]]; then
    RUNNING_BIN_NAME=$(basename "$LOCAL_BIN")
    if pgrep -u "$REAL_USER" -f "$RUNNING_BIN_NAME" > /dev/null 2>&1; then
        echo -e "\n[!] Active Process Block: $APP_NAME is currently running."
        read -r -p "[?] Kill process, deploy workspace matrix, and auto-restart? [Y/n]: " run_res
        if [[ ! "${run_res,,}" =~ ^(no|n) ]]; then
            pkill -u "$REAL_USER" -f "$RUNNING_BIN_NAME" || true; sleep 1.5
            pkill -9 -u "$REAL_USER" -f "$RUNNING_BIN_NAME" || true
            if [[ "$CLI_ONLY" != "true" ]]; then RESTART_REQD=true; fi
        else
            echo "[-] Update cycle canceled to keep app active."
            exit 0
        fi
    fi
fi

# 8. File Erasure and Allocation
echo "[*] Deep cleaning legacy directory mappings to clear stale libraries..."
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

echo "[*] Synchronizing updated frameworks into installation path..."
cp -R "$EXTRACTED_FOLDER"/. "$INSTALL_DIR/"

if [[ -n "$BINARY_PATH" && "$BINARY_PATH" != "null" ]]; then
    REAL_BINARY="$INSTALL_DIR/$BINARY_PATH"
else
    REAL_BINARY=$(find "$INSTALL_DIR" -maxdepth 1 -type f -iname "$BINARY_PATTERN" | head -n 1)
    [[ -z "$REAL_BINARY" ]] && REAL_BINARY=$(find "$INSTALL_DIR" -maxdepth 1 -type f -executable | head -n 1)
fi

if [[ -z "$REAL_BINARY" || ! -f "$REAL_BINARY" ]]; then
    echo "[-] Critical Error: Execution file vector verification failed inside installation target." >&2
    exit 1
fi

chmod +x "$REAL_BINARY"
ln -sf "$REAL_BINARY" "$BIN_LINK"

# 9. Dynamic Linux Desktop Icon Integration Layout
if [[ "$CLI_ONLY" != "true" ]]; then
    echo "[*] Scanning workspace assets for Application Desktop Graphics..."
    ICON_PATH=$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 3 -type f \( -name "icon.png" -o -name "icon.svg" -o -name "${APP_ID}.png" -o -name "${APP_ID}.svg" \) | head -n 1 || true)
    
    if [[ -z "$ICON_PATH" ]]; then
        ICON_PATH=$(find "$INSTALL_DIR" -maxdepth 2 -type f \( -name "*.png" -o -name "*.svg" \) | head -n 1 || true)
    fi

    DESKTOP_FILE="$DESKTOP_DIR/${APP_ID}.desktop"
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

# 10. Post-Execution cleanup hooks
if [ "$DOWNLOAD" = true ]; then
    if [ "$CLEANUP" = true ]; then
        echo "[*] Removing compressed remote runtime package artifacts..."
    else
        URL_FILE_NAME=$(basename "$DOWNLOAD_URL" | sed 's/%20/ /g')
        [[ "$URL_FILE_NAME" == "download"* || -z "$URL_FILE_NAME" ]] && URL_FILE_NAME="${APP_ID}-linux.tar.gz"
        OUTPUT_DEST="$(pwd)/$URL_FILE_NAME"
        mv -f "$TARBALL" "$OUTPUT_DEST"
        [[ -n "${SUDO_USER:-}" ]] && chown "${SUDO_USER}:" "$OUTPUT_DEST"
        echo "[i] Local installation backup kept at: $OUTPUT_DEST"
    fi
fi

# 11. Environment variables reload check for UI relaunch mapping
if [ "$RESTART_REQD" = true ]; then
    echo "[*] Relaunching application window environment inside active desktop framework layer..."
    sudo -u "$REAL_USER" env \
        DISPLAY="${DISPLAY:-:0}" \
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
        XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" \
        nohup "$BIN_LINK" > /dev/null 2>&1 &
    echo "[+] Application successfully brought back online."
fi

echo -e "\n[+] Success! $APP_NAME has been deployed via dopt."