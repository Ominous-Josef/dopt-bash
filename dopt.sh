#!/usr/bin/env bash
# dopt - Directory Optional Package Manager engine for standalone Linux software.
# Author: Ominous-Josef
# Version: 1.0.1
# License: GPLv3
# Description: A lightweight, manifest-driven package manager for standalone Linux tarballs.

set -euo pipefail

# Default flag parameters
MANIFEST=""
DOWNLOAD=false
CLEANUP=false
FORCE_INSTALL=false
SEARCH_DIR="."
FILE_PATH=""
CUSTOM_URL=""
SYMLINK_CLI=""
RESTART_REQD=false
GLOBAL_INSTALL=false

show_help() {
    echo "dopt - Dynamic Optional Package Manager"
    echo "Usage: ./dopt.sh [options]"
    echo ""
    echo "Manifest (Optional):"
    echo "  -m, --manifest <json>   The application manifest recipe configuration file"
    echo "  -a, --app-id <id>       Provide App ID directly if not using a manifest"
    echo "  -s, --symlink-as <name> Command name to link (overrides the manifest's 'symlink_as')"
    echo ""
    echo "Deployment Targets (Choose one. Defaults to scanning '.' if omitted):"
    echo "  -d, --download          Download using the manifest's default server endpoint"
    echo "  -u, --url <url>         Download using a specific direct link override"
    echo "  -f, --file <path>       Directly deploy from a local archive package file"
    echo "  -p, --path <dir>        Scan a specific directory folder for a matching local archive"
    echo ""
    echo "Modifiers:"
    echo "  -g, --global            Install system-wide to /opt (requires sudo)"
    echo "  -c, --cleanup           Delete downloaded installer archive after a successful setup"
    echo "  -i, --install           Skip confirmation prompts; auto-terminate and relaunch a running app"
    echo "  -h, --help              Show this help menu"
    echo ""
    echo "Documentation & Examples:"
    echo "  Full documentation: https://github.com/Ominous-Josef/dopt-bash"
    echo "  Manifest template:  See 'examples/example-manifest.json'"
}

# Allowlist for anything used as a path component (app IDs, symlink names)
NAME_REGEX='^[A-Za-z0-9][A-Za-z0-9._-]*$'

NAME_RULES="allowed: letters, digits, '.', '_', '-'; must not start with a symbol or contain '..'"

is_valid_name() {
    [[ "$1" =~ $NAME_REGEX && "$1" != *".."* ]]
}

validate_name() {
    local label="$1" value="$2"
    if ! is_valid_name "$value"; then
        echo "[-] CRITICAL: Security abort. Invalid $label '$value' ($NAME_RULES)." >&2
        exit 1
    fi
}

manifest_get() {
    jq -r --arg k "$1" '.[$k] // empty' "$MANIFEST"
}

# Sets OWNER_PKG/OWNER_TOOL if a system package owns the directory (or a few files inside it)
package_owner() {
    local f out
    OWNER_PKG=""
    OWNER_TOOL=""
    while IFS= read -r f; do
        if command -v rpm >/dev/null 2>&1 && out=$(rpm -qf --qf '%{NAME}\n' -- "$f" 2>/dev/null); then
            OWNER_PKG=$(head -n 1 <<< "$out"); OWNER_TOOL="dnf"; return 0
        fi
        if command -v dpkg >/dev/null 2>&1 && out=$(dpkg -S -- "$f" 2>/dev/null); then
            OWNER_PKG=$(head -n 1 <<< "$out" | cut -d: -f1 | cut -d, -f1); OWNER_TOOL="apt"; return 0
        fi
    done < <({ printf '%s\n' "$1"; find "$1" -maxdepth 2 -type f 2>/dev/null | head -n 5; })
    return 1
}

# 1. Parse command-line inputs
ORIG_ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--manifest) MANIFEST="$2"; shift 2 ;;
        -a|--app-id)   APP_ID_CLI="$2"; shift 2 ;;
        -s|--symlink-as) SYMLINK_CLI="$2"; shift 2 ;;
        -d|--download) DOWNLOAD=true; shift ;;
        -c|--cleanup)  CLEANUP=true; shift ;;
        -g|--global)   GLOBAL_INSTALL=true; shift ;;
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

# 2. Secure environment validation hooks & Path Resolution
REAL_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

if [ "$GLOBAL_INSTALL" = true ]; then
    if [[ $EUID -ne 0 ]]; then
        echo "[-] Error: Global deployment requires root context. Re-run command using sudo." >&2
        exit 1
    fi
    OPT_DIR="/opt"
    BIN_LINK_DIR="/usr/local/bin"
    DESKTOP_DIR="/usr/share/applications"
else
    if [[ $EUID -eq 0 ]]; then
        echo "[-] Error: Local installation should not be run as root. Re-run without sudo, or pass --global for system-wide deployment." >&2
        exit 1
    fi
    OPT_DIR="$USER_HOME/.local/opt"
    BIN_LINK_DIR="$USER_HOME/.local/bin"
    DESKTOP_DIR="$USER_HOME/.local/share/applications"
    
    mkdir -p "$OPT_DIR" "$BIN_LINK_DIR" "$DESKTOP_DIR"
fi

# 3. Resolve App ID
if [[ -n "$MANIFEST" && -f "$MANIFEST" ]]; then
    APP_ID=$(manifest_get app_id)
    [[ -z "$APP_ID" ]] && { echo "[-] Error: Manifest is missing required field 'app_id'." >&2; exit 1; }
else
    APP_ID="${APP_ID_CLI:-}"
    if [[ -z "$APP_ID" ]]; then
        echo "[*] No manifest provided. Using interactive setup..."
        echo "[i] Tip: Type '?' to see your currently installed applications."
        while true; do
            read -r -p "[?] Enter App ID (e.g. com.example.app): " APP_ID
            if [[ "$APP_ID" == "?" ]]; then
                echo -e "\n--- Installed Applications in $OPT_DIR ---"
                for dir in "$OPT_DIR"/*/; do
                    [[ -d "$dir" ]] && echo "- $(basename "$dir")"
                done
                echo -e "--------------------------------------\n"
            else
                break
            fi
        done
    fi
    [[ -z "$APP_ID" ]] && { echo "[-] Error: App ID is required."; exit 1; }
fi
validate_name "App ID" "$APP_ID"

# Defaults auto-populated from a previous installation (and from the global app when going local)
DEF_APP_NAME=""
DEF_SYMLINK_NAME=""
DEF_CLI_ANS=""
DEF_BINARY_PATTERN=""
DEF_ICON_MANIFEST=""
DEF_CATEGORIES=""
APPEND_LOCAL_NAME=false

if [ "$GLOBAL_INSTALL" = false ] && [[ -d "/opt/$APP_ID" ]]; then
    echo -e "\n[!] Found existing system-wide installation of $APP_ID at /opt/$APP_ID."
    echo "    1) Elevate privileges to update the global installation"
    echo "    2) Proceed with an isolated local installation"
    echo "    3) Abort"
    read -r -p "[?] Choose an action [1-3]: " action_res
    case "$action_res" in
        1)
            echo "[*] Elevating privileges..."
            SELF_PATH=$(readlink -f "$0")
            if [[ -z "$MANIFEST" && -z "${APP_ID_CLI:-}" ]]; then
                exec sudo "$SELF_PATH" -g "${ORIG_ARGS[@]}" -a "$APP_ID"
            else
                exec sudo "$SELF_PATH" -g "${ORIG_ARGS[@]}"
            fi
            ;;
        2)
            echo "[*] Proceeding with isolated local installation..."
            read -r -p "[?] To prevent the local app from hiding the global app in your menu, we can append '-local' to the App ID and Name. Do this now? [Y/n]: " rename_res
            if [[ ! "${rename_res,,}" =~ ^(no|n) ]]; then
                GLOBAL_DESKTOP="/usr/share/applications/${APP_ID}.desktop"
                if [[ -f "$GLOBAL_DESKTOP" ]]; then
                    GLOBAL_NAME=$(grep "^Name=" "$GLOBAL_DESKTOP" | cut -d= -f2- || true)
                    [[ -n "$GLOBAL_NAME" ]] && DEF_APP_NAME="$GLOBAL_NAME (Local)"
                fi
                APP_ID="${APP_ID}-local"
                validate_name "App ID" "$APP_ID"
                APPEND_LOCAL_NAME=true
                echo "[i] App ID updated to: $APP_ID"
            fi
            ;;
        *)
            echo "[-] Deployment aborted."
            exit 1
            ;;
    esac
fi

# 3.5 Source Validation & Recovery
if [ "$DOWNLOAD" = false ] && [[ -z "$FILE_PATH" ]]; then
    [[ "$SEARCH_DIR" == "~"* ]] && SEARCH_DIR="${SEARCH_DIR/\~/$USER_HOME}"
    LATEST_TARBALL=$(ls -t -- "$SEARCH_DIR"/*"${APP_ID}"*.tar.gz 2>/dev/null | head -n 1 || true)
    if [[ -z "$LATEST_TARBALL" ]]; then
        echo -e "\n[-] Could not automatically find a package matching '*${APP_ID}*.tar.gz' in '$SEARCH_DIR'."
        echo "[?] How would you like to provide the application payload?"
        echo "    1) Provide a direct download URL"
        echo "    2) Provide the exact local file path"
        echo "    3) Abort"
        read -r -p "[?] Choose an action [1-3]: " source_res
        case "$source_res" in
            1)
                read -r -p "[?] Enter full URL (e.g. https://...): " CUSTOM_URL
                [[ -z "$CUSTOM_URL" ]] && { echo "[-] URL cannot be empty."; exit 1; }
                DOWNLOAD=true
                ;;
            2)
                read -r -p "[?] Enter exact local file path: " FILE_PATH
                [[ -z "$FILE_PATH" ]] && { echo "[-] Path cannot be empty."; exit 1; }
                [[ "$FILE_PATH" == "~"* ]] && FILE_PATH="${FILE_PATH/\~/$USER_HOME}"
                if [[ ! -f "$FILE_PATH" ]]; then 
                    echo "[-] Path fault: Target file missing: $FILE_PATH" >&2; exit 1
                fi
                ;;
            *)
                echo "[-] Deployment aborted."
                exit 1
                ;;
        esac
    else
        TARBALL_SCANNED="$LATEST_TARBALL"
    fi
elif [[ -n "$FILE_PATH" ]]; then
    [[ "$FILE_PATH" == "~"* ]] && FILE_PATH="${FILE_PATH/\~/$USER_HOME}"
    if [[ ! -f "$FILE_PATH" ]]; then 
        echo "[-] Path fault: Target file missing: $FILE_PATH" >&2; exit 1
    fi
fi

# Defaults from the previous installation: only look where dopt itself writes
DESKTOP_FILE="$DESKTOP_DIR/${APP_ID}.desktop"
if [[ -d "$OPT_DIR/$APP_ID" ]]; then
    EXISTING_LINK=$(find "$BIN_LINK_DIR" -maxdepth 1 -type l -lname "$OPT_DIR/$APP_ID/*" 2>/dev/null | head -n 1 || true)
    if [[ -n "$EXISTING_LINK" ]]; then
        DEF_SYMLINK_NAME=$(basename "$EXISTING_LINK")
        DEF_BINARY_PATTERN=$(basename "$(readlink -- "$EXISTING_LINK")")
    fi

    if [[ -f "$DESKTOP_FILE" ]]; then
        OLD_NAME=$(grep -m 1 "^Name=" "$DESKTOP_FILE" | cut -d= -f2- || true)
        [[ -n "$OLD_NAME" ]] && DEF_APP_NAME="$OLD_NAME"
        DEF_ICON_FULL=$(grep -m 1 "^Icon=" "$DESKTOP_FILE" | cut -d= -f2- || true)
        [[ -n "$DEF_ICON_FULL" ]] && DEF_ICON_MANIFEST=$(basename "$DEF_ICON_FULL")
        DEF_CATEGORIES=$(grep -m 1 "^Categories=" "$DESKTOP_FILE" | cut -d= -f2- || true)
        DEF_CLI_ANS="n"
    elif [[ -n "$EXISTING_LINK" ]]; then
        DEF_CLI_ANS="y"
    fi
fi

# Ingest and extract remaining values
if [[ -n "$MANIFEST" && -f "$MANIFEST" ]]; then
    APP_NAME=$(manifest_get name)
    APP_NAME=${APP_NAME:-$APP_ID}
    APP_COMMENT=$(manifest_get comment)
    BINARY_PATTERN=$(manifest_get binary_pattern)
    BINARY_PATH=$(manifest_get binary_path)
    if [[ -z "$BINARY_PATTERN" && -z "$BINARY_PATH" ]]; then
        echo "[-] Error: Manifest must define 'binary_path' or 'binary_pattern'." >&2
        exit 1
    fi
    ICON_PATH_MANIFEST=$(manifest_get icon_path)
    CLI_ONLY=$(manifest_get cli_only)
    SYMLINK_NAME=${SYMLINK_CLI:-$(manifest_get symlink_as)}
    SYMLINK_NAME=${SYMLINK_NAME:-$APP_ID}
    APP_CATEGORIES=$(manifest_get categories)
    APP_CATEGORIES=${APP_CATEGORIES:-Utility;}
    EXEC_FLAGS=$(manifest_get exec_flags)
else
    [[ -d "$OPT_DIR/$APP_ID" ]] && echo "[*] Existing installation detected. Auto-populating defaults..."
    
    read -r -p "[?] Enter Application Name [${DEF_APP_NAME:-$APP_ID}]: " APP_NAME
    APP_NAME=${APP_NAME:-${DEF_APP_NAME:-$APP_ID}}
    
    if [[ -n "$SYMLINK_CLI" ]]; then
        SYMLINK_NAME="$SYMLINK_CLI"
    else
        read -r -p "[?] Enter executable symlink name [${DEF_SYMLINK_NAME:-$APP_ID}]: " SYMLINK_NAME
        SYMLINK_NAME=${SYMLINK_NAME:-${DEF_SYMLINK_NAME:-$APP_ID}}
    fi
    
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

    read -r -p "[?] Enter target binary name to link [${DEF_BINARY_PATTERN:-$SYMLINK_NAME}]: " BINARY_PATTERN
    BINARY_PATTERN=${BINARY_PATTERN:-${DEF_BINARY_PATTERN:-$SYMLINK_NAME}}
    BINARY_PATH=""
    
    icon_prompt_def="(leave blank to auto-detect)"
    [[ -n "$DEF_ICON_MANIFEST" ]] && icon_prompt_def="[$DEF_ICON_MANIFEST]"
    read -r -p "[?] Enter icon file path/name $icon_prompt_def: " ICON_PATH_MANIFEST
    ICON_PATH_MANIFEST=${ICON_PATH_MANIFEST:-$DEF_ICON_MANIFEST}
    
    read -r -p "[?] Enter Desktop Category (e.g. Utility;, Development;, Game;) [${DEF_CATEGORIES:-Utility;}]: " APP_CATEGORIES
    APP_CATEGORIES=${APP_CATEGORIES:-${DEF_CATEGORIES:-Utility;}}
    [[ -n "$APP_CATEGORIES" && "$APP_CATEGORIES" != *";" ]] && APP_CATEGORIES="${APP_CATEGORIES};"
    
    EXEC_FLAGS=""
fi

validate_name "symlink name" "$SYMLINK_NAME"

if [[ "$APPEND_LOCAL_NAME" = true && "$APP_NAME" != *" (Local)" ]]; then
    APP_NAME="$APP_NAME (Local)"
fi

BIN_LINK="$BIN_LINK_DIR/$SYMLINK_NAME"
# dopt only ever installs into (and deletes) $OPT_DIR/$APP_ID
INSTALL_DIR="$OPT_DIR/$APP_ID"
STAGE_DIR="$OPT_DIR/.${APP_ID}.dopt-new"
BACKUP_DIR="$OPT_DIR/.${APP_ID}.dopt-old"

# Refuse to modify any path that isn't a direct child of $OPT_DIR managed by dopt
assert_managed_dir() {
    local target parent name
    target=$(readlink -m -- "$1")
    parent=$(dirname -- "$target")
    name=$(basename -- "$target")
    if [[ "$parent" != "$(readlink -m -- "$OPT_DIR")" ]] ||
       [[ ! "${name#.}" =~ $NAME_REGEX || "$name" == *".."* ]] ||
       [[ "$name" != "$APP_ID" && "$name" != ".${APP_ID}.dopt-new" && "$name" != ".${APP_ID}.dopt-old" ]]; then
        echo "[-] CRITICAL: Safety abort. Refusing to modify $target (outside dopt's managed directory $OPT_DIR)." >&2
        exit 1
    fi
}

# True if $1 resolves to a path inside $2/
path_is_inside() {
    local resolved
    resolved=$(readlink -m -- "$1")
    [[ "$resolved" == "$(readlink -m -- "$2")/"* ]]
}

# 4. Ownership: only upgrade folders dopt created (marked with .dopt), never package-managed ones
MARKER_NAME=".dopt"
echo "[*] Auditing environment path structures for $APP_NAME..."
if [[ -d "$INSTALL_DIR" && ! -f "$INSTALL_DIR/$MARKER_NAME" ]]; then
    if package_owner "$INSTALL_DIR"; then
        echo "[-] Error: $INSTALL_DIR belongs to the system package '$OWNER_PKG'. dopt won't modify package-managed files." >&2
        echo "[i] To use the tarball version, either install it alongside with a different App ID," >&2
        echo "    or remove the package first: sudo $OWNER_TOOL remove $OWNER_PKG" >&2
        exit 1
    fi
    echo -e "\n[!] $INSTALL_DIR exists but wasn't installed by dopt (no $MARKER_NAME marker)."
    echo "    Installs made by older versions of dopt ask this once."
    if [ "$FORCE_INSTALL" = true ]; then
        echo "[-] Error: Refusing to replace it in forced (-i) mode. Re-run without -i to confirm." >&2
        exit 1
    fi
    read -r -p "[?] Replace it with the new version? [y/N]: " replace_res
    if [[ ! "${replace_res,,}" =~ ^(yes|y)$ ]]; then
        echo "[-] Deployment aborted. $INSTALL_DIR was not modified."
        exit 0
    fi
fi

# 4.5 Make sure the command name doesn't belong to something dopt didn't install
abort_name_clash() {
    if [ "$FORCE_INSTALL" = true ]; then
        echo "[-] Error: Cannot ask for a different command name in forced (-i) mode." >&2
    fi
    echo "[-] Deployment aborted. Re-run with -s <name> to use a different command name." >&2
    exit 1
}

prompt_new_symlink_name() {
    local new_name
    while true; do
        read -r -p "[?] Enter a different command name: " new_name
        if [[ -z "$new_name" ]]; then
            echo "[-] Name cannot be empty."
        elif ! is_valid_name "$new_name"; then
            echo "[-] Invalid name '$new_name' ($NAME_RULES)."
        else
            SYMLINK_NAME="$new_name"
            SYMLINK_RENAMED=true
            return 0
        fi
    done
}

lookup_command() {
    if [[ $EUID -eq 0 ]]; then
        sudo -u "$REAL_USER" bash -lc 'command -v -- "$1" || true' _ "$1" 2>/dev/null | tail -n 1 || true
    else
        command -v -- "$1" 2>/dev/null || true
    fi
}

SYMLINK_RENAMED=false
while true; do
    BIN_LINK="$BIN_LINK_DIR/$SYMLINK_NAME"

    # The link path itself is taken by something that isn't ours: never overwrite it
    if [[ -e "$BIN_LINK" || -L "$BIN_LINK" ]] &&
       { [[ ! -L "$BIN_LINK" ]] || ! path_is_inside "$(readlink -- "$BIN_LINK")" "$INSTALL_DIR"; }; then
        echo -e "\n[!] $BIN_LINK already exists and wasn't installed by dopt for $APP_ID."
        [ "$FORCE_INSTALL" = true ] && abort_name_clash
        echo "    1) Choose a different command name"
        echo "    2) Abort"
        read -r -p "[?] Choose an action [1-2] (default 1): " clash_res
        case "${clash_res:-1}" in
            1) prompt_new_symlink_name; continue ;;
            *) abort_name_clash ;;
        esac
    fi

    # The name exists elsewhere on PATH: the new link would shadow it (or be shadowed by it)
    EXISTING_BIN=$(lookup_command "$SYMLINK_NAME")
    if [[ "$EXISTING_BIN" == /* && "$EXISTING_BIN" != "$BIN_LINK" ]]; then
        BASE_APP_ID="${APP_ID%-local}"
        if path_is_inside "$EXISTING_BIN" "$INSTALL_DIR" ||
           path_is_inside "$EXISTING_BIN" "/opt/$BASE_APP_ID" ||
           path_is_inside "$EXISTING_BIN" "$USER_HOME/.local/opt/$BASE_APP_ID" ||
           path_is_inside "$EXISTING_BIN" "$USER_HOME/.local/opt/$BASE_APP_ID-local"; then
            echo "[!] Warning: '$SYMLINK_NAME' also resolves to $EXISTING_BIN (another installation of this app). Whichever comes first in PATH will run."
        else
            echo -e "\n[!] The command '$SYMLINK_NAME' already exists at $EXISTING_BIN and wasn't installed by dopt."
            [ "$FORCE_INSTALL" = true ] && abort_name_clash
            echo "    1) Choose a different command name"
            echo "    2) Continue anyway (which '$SYMLINK_NAME' runs will depend on PATH order)"
            echo "    3) Abort"
            read -r -p "[?] Choose an action [1-3] (default 1): " clash_res
            case "${clash_res:-1}" in
                1) prompt_new_symlink_name; continue ;;
                2) echo "[!] Continuing: $BIN_LINK will coexist with $EXISTING_BIN." ;;
                *) abort_name_clash ;;
            esac
        fi
    fi
    break
done

SYMLINK_HINT=""
if [[ -n "$SYMLINK_CLI" || "$SYMLINK_RENAMED" = true ]]; then
    SYMLINK_HINT=" -s \"$SYMLINK_NAME\""
fi
if [[ "$SYMLINK_RENAMED" = true && -n "$MANIFEST" ]]; then
    echo "[i] Tip: The manifest's 'symlink_as' doesn't match the name you chose. Update it, or pass -s \"$SYMLINK_NAME\" on future runs."
fi

if [[ -d "$INSTALL_DIR" ]]; then
    echo "[+] Map match: Found existing installation at $INSTALL_DIR"
elif [ "$FORCE_INSTALL" = false ]; then
    echo ""
    read -r -p "[?] No version found. Perform a clean installation of $APP_NAME at $INSTALL_DIR? [Y/n]: " inst_res
    if [[ "${inst_res,,}" =~ ^(no|n) ]]; then
        echo "[-] Deployment aborted."
        exit 0
    fi
fi

# 5. Target Architecture Resolution and Source Acquisition
TMP_DIR=$(mktemp -d -t dopt-workspace-XXXXXXXX)
cleanup_workspace() {
    local exit_code=$?
    # Roll back an interrupted swap and drop any half-built staging copy
    if [[ -d "$BACKUP_DIR" && ! -e "$INSTALL_DIR" ]]; then
        if mv -- "$BACKUP_DIR" "$INSTALL_DIR" 2>/dev/null; then
            echo -e "\n[i] Update failed. The previous installation was restored at $INSTALL_DIR"
        fi
    fi
    [[ -e "$STAGE_DIR" ]] && rm -rf -- "$STAGE_DIR"
    if [[ $exit_code -ne 0 && "$DOWNLOAD" = true && -f "${TARBALL:-}" && "$CLEANUP" = false ]]; then
        URL_FILE_NAME=$(basename "${DOWNLOAD_URL:-}" | sed 's/%20/ /g')
        [[ "$URL_FILE_NAME" == "download"* || -z "$URL_FILE_NAME" ]] && URL_FILE_NAME="${APP_ID}-linux.tar.gz"
        OUTPUT_DEST="$(pwd)/$URL_FILE_NAME"
        if mv -f -- "$TARBALL" "$OUTPUT_DEST" 2>/dev/null; then
            [[ -n "${SUDO_USER:-}" ]] && chown -- "${SUDO_USER}:" "$OUTPUT_DEST" 2>/dev/null
            echo -e "\n[i] The downloaded update archive has been preserved at: $OUTPUT_DEST"
            echo "[!] To apply this update later without re-downloading, run:"
            [[ "$GLOBAL_INSTALL" = true ]] && SUDO_PREFIX="sudo " || SUDO_PREFIX=""
            if [[ -n "${MANIFEST:-}" && -f "${MANIFEST:-}" ]]; then
                echo "    ${SUDO_PREFIX}./dopt.sh -m \"$MANIFEST\" -f \"$OUTPUT_DEST\"${SYMLINK_HINT:-}"
            else
                echo "    ${SUDO_PREFIX}./dopt.sh -a \"$APP_ID\" -f \"$OUTPUT_DEST\"${SYMLINK_HINT:-}"
            fi
        fi
    fi
    rm -rf "$TMP_DIR"
    exit $exit_code
}
trap cleanup_workspace EXIT

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
        DOWNLOAD_URL=$(manifest_get "$ARCH_KEY")
    else
        DOWNLOAD_URL=""
    fi
    
    if [[ -z "$DOWNLOAD_URL" ]]; then
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
    TARBALL="$FILE_PATH"
else
    TARBALL="${TARBALL_SCANNED:-}"
    if [[ -z "$TARBALL" ]]; then
        echo "[-] Critical Fault: Scanned tarball reference lost." >&2; exit 1
    fi
fi

# 6. Unpack and Parse Sandbox Interior
echo "[*] Extracting execution code assets..."
tar -xzf "$TARBALL" -C "$TMP_DIR"

EXTRACTED_FOLDER=$(find "$TMP_DIR" -mindepth 1 -maxdepth 2 -type d -iname "*${APP_ID}*" | head -n 1)
[[ -z "$EXTRACTED_FOLDER" ]] && EXTRACTED_FOLDER=$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[[ -z "$EXTRACTED_FOLDER" ]] && EXTRACTED_FOLDER="$TMP_DIR"

# 7. Stage the new version next to the live one, so the swap is a pair of renames
if [[ ! -w "$OPT_DIR" ]]; then
    echo "[-] Error: Permission denied. You do not have write access to $OPT_DIR." >&2
    if [[ "$OPT_DIR" == "/opt" ]]; then
        echo "[i] This is a system-wide installation. Try running dopt with sudo and the --global flag." >&2
    fi
    exit 1
fi

assert_managed_dir "$STAGE_DIR"
assert_managed_dir "$BACKUP_DIR"
# Recover from a previous run that was interrupted mid-swap, then clear leftovers
if [[ -d "$BACKUP_DIR" && ! -e "$INSTALL_DIR" ]]; then
    mv -- "$BACKUP_DIR" "$INSTALL_DIR"
fi
rm -rf -- "$STAGE_DIR" "$BACKUP_DIR"

echo "[*] Synchronizing updated frameworks into staging path..."
mkdir -p "$STAGE_DIR"
cp -R "$EXTRACTED_FOLDER"/. "$STAGE_DIR/"

if [[ -n "$BINARY_PATH" ]]; then
    STAGED_BINARY="$STAGE_DIR/$BINARY_PATH"
else
    STAGED_BINARY=$(find "$STAGE_DIR" -maxdepth 1 -type f -iname "$BINARY_PATTERN" | head -n 1)
    [[ -z "$STAGED_BINARY" ]] && STAGED_BINARY=$(find "$STAGE_DIR" -maxdepth 1 -type f -executable ! -name "chrome-sandbox" ! -name "crashpad_handler" | head -n 1)
fi

if [[ -z "$STAGED_BINARY" || ! -f "$STAGED_BINARY" ]] || ! path_is_inside "$STAGED_BINARY" "$STAGE_DIR"; then
    echo "[-] Critical Error: Execution file vector verification failed inside the new package. The existing installation was not touched." >&2
    exit 1
fi
BINARY_REL_PATH="${STAGED_BINARY#"$STAGE_DIR"/}"

# Processes whose executable (or argv[0]) lives inside the install dir or is the app's symlink
find_app_pids() {
    local pid exe argv0 install_real
    [[ -d "$INSTALL_DIR" ]] || return 0
    install_real=$(readlink -m -- "$INSTALL_DIR")
    for pid in $(pgrep -u "$REAL_USER" 2>/dev/null || true); do
        [[ "$pid" == "$$" ]] && continue
        exe=$(readlink -- "/proc/$pid/exe" 2>/dev/null || true)
        argv0=""
        { IFS= read -r -d '' argv0 < "/proc/$pid/cmdline"; } 2>/dev/null || true
        if [[ "$exe" == "$install_real/"* || "$argv0" == "$install_real/"* ||
              "$argv0" == "$INSTALL_DIR/"* || "$argv0" == "$BIN_LINK" ]]; then
            echo "$pid"
        fi
    done
}

terminate_app() {
    local pid alive
    kill -TERM "$@" 2>/dev/null || true
    for _ in {1..30}; do
        alive=false
        for pid in "$@"; do kill -0 "$pid" 2>/dev/null && alive=true; done
        [[ "$alive" = false ]] && return 0
        sleep 0.1
    done
    kill -KILL "$@" 2>/dev/null || true
}

mapfile -t APP_PIDS < <(find_app_pids)
if [[ ${#APP_PIDS[@]} -gt 0 ]]; then
    if [ "$FORCE_INSTALL" = true ]; then
        echo -e "\n[!] Warning: Forced installation active. Automatically terminating active processes for update..."
        terminate_app "${APP_PIDS[@]}"
        if [[ "$CLI_ONLY" != "true" ]]; then RESTART_REQD=true; fi
    else
        echo -e "\n[!] Active Process Block: $APP_NAME is currently running."
        read -r -p "[?] Kill process to deploy update? [Y/n]: " run_res
        if [[ ! "${run_res,,}" =~ ^(no|n) ]]; then
            terminate_app "${APP_PIDS[@]}"
            if [[ "$CLI_ONLY" != "true" ]]; then RESTART_REQD=true; fi
        else
            echo "[-] Update cycle canceled to keep app active."
            RESUME_FILE=""
            if [ "$DOWNLOAD" = true ]; then
                if [ "$CLEANUP" = false ]; then
                    URL_FILE_NAME=$(basename "$DOWNLOAD_URL" | sed 's/%20/ /g')
                    [[ "$URL_FILE_NAME" == "download"* || -z "$URL_FILE_NAME" ]] && URL_FILE_NAME="${APP_ID}-linux.tar.gz"
                    OUTPUT_DEST="$(pwd)/$URL_FILE_NAME"
                    mv -f -- "$TARBALL" "$OUTPUT_DEST"
                    [[ -n "${SUDO_USER:-}" ]] && chown -- "${SUDO_USER}:" "$OUTPUT_DEST"
                    echo "[i] The downloaded update archive has been preserved at: $OUTPUT_DEST"
                    RESUME_FILE="$OUTPUT_DEST"
                fi
            elif [[ -n "${FILE_PATH:-}" ]]; then
                RESUME_FILE="$FILE_PATH"
            elif [[ -n "${TARBALL:-}" ]]; then
                RESUME_FILE="$TARBALL"
            fi

            if [[ -n "$RESUME_FILE" ]]; then
                echo -e "\n[!] To apply this update later without re-downloading, run:"
                if [[ -n "$MANIFEST" && -f "$MANIFEST" ]]; then
                    echo "    sudo ./dopt.sh -m \"$MANIFEST\" -f \"$RESUME_FILE\"$SYMLINK_HINT"
                else
                    echo "    sudo ./dopt.sh -a \"$APP_ID\" -f \"$RESUME_FILE\"$SYMLINK_HINT"
                fi
            fi
            exit 0
        fi
    fi
fi

# Swap: live -> backup, staged -> live, then drop the backup. The exit trap restores the backup on failure.
assert_managed_dir "$INSTALL_DIR"
printf 'app_id=%s\n' "$APP_ID" > "$STAGE_DIR/$MARKER_NAME"
echo "[*] Swapping in the new version to clear stale libraries..."
if [[ -e "$INSTALL_DIR" ]]; then
    mv -- "$INSTALL_DIR" "$BACKUP_DIR"
fi
mv -- "$STAGE_DIR" "$INSTALL_DIR"
rm -rf -- "$BACKUP_DIR"

REAL_BINARY="$INSTALL_DIR/$BINARY_REL_PATH"

if [[ -n "${DEF_SYMLINK_NAME:-}" && "$DEF_SYMLINK_NAME" != "$SYMLINK_NAME" ]]; then
    OLD_BIN_LINK="$BIN_LINK_DIR/$DEF_SYMLINK_NAME"
    if [[ -L "$OLD_BIN_LINK" ]] && path_is_inside "$(readlink -- "$OLD_BIN_LINK")" "$INSTALL_DIR"; then
        echo "[*] Cleaning up legacy symlink at $OLD_BIN_LINK..."
        rm -f -- "$OLD_BIN_LINK"
    fi
fi

chmod +x "$REAL_BINARY"
ln -sfn "$REAL_BINARY" "$BIN_LINK"

# 8. Dynamic Linux Desktop Icon Integration Layout
if [[ "$CLI_ONLY" != "true" ]]; then
    echo "[*] Scanning workspace assets for Application Desktop Graphics..."
    ICON_PATH=""
    
    if [[ -n "${ICON_PATH_MANIFEST:-}" ]]; then
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
    if [[ -f "$DESKTOP_FILE" ]]; then
        echo "[*] Removing previous desktop shortcut at $DESKTOP_FILE..."
        rm -f -- "$DESKTOP_FILE"
    fi
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
            if [[ $EUID -eq 0 ]]; then
                sudo -u "$REAL_USER" env DISPLAY="${DISPLAY:-:0}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" nohup "$BIN_LINK" > /dev/null 2>&1 &
            else
                env DISPLAY="${DISPLAY:-:0}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" nohup "$BIN_LINK" > /dev/null 2>&1 &
            fi
            echo "[+] Application successfully brought back online."
        fi
    else
        echo ""
        read -r -p "[?] Deployment complete. Would you like to launch $APP_NAME now? [Y/n]: " launch_ans
        if [[ ! "${launch_ans,,}" =~ ^(no|n) ]]; then
            echo "[*] Launching application..."
            if [[ $EUID -eq 0 ]]; then
                sudo -u "$REAL_USER" env DISPLAY="${DISPLAY:-:0}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" nohup "$BIN_LINK" > /dev/null 2>&1 &
            else
                env DISPLAY="${DISPLAY:-:0}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" nohup "$BIN_LINK" > /dev/null 2>&1 &
            fi
            echo "[+] Application successfully launched."
        fi
    fi
fi

echo -e "\n[+] Success! $APP_NAME has been deployed via dopt."