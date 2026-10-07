#!/usr/bin/env bash
# dopt - Directory Optional Package Manager engine for standalone Linux software.
# Author: Ominous-Josef
# Version: 2.1.0
# License: GPLv3
# Description: A lightweight, manifest-driven package manager for standalone Linux tarballs.

set -euo pipefail

DOPT_VERSION="2.1.0"

# Default flag parameters
MANIFEST=""
DOWNLOAD=false
CLEANUP=false
FORCE_INSTALL=false
SHA256_EXPECTED=""
FILE_PATH=""
CUSTOM_URL=""
SYMLINK_CLI=""
RESTART_REQD=false
GLOBAL_INSTALL=false

# Output style. Prefixes keep their meaning without color: [n/N] step, [+] success, [!] warning,
# [-] error (stderr), [?] prompt; details are indented under their step.
# Color only when the stream is a terminal and NO_COLOR is unset.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RESET=$'\e[0m'
else
    C_BOLD=""; C_DIM=""; C_GREEN=""; C_YELLOW=""; C_RESET=""
fi
# Errors and read -p prompts go to stderr, so they follow stderr's terminal state
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    E_BOLD=$'\e[1m'; E_RED=$'\e[31m'; E_RESET=$'\e[0m'
else
    E_BOLD=""; E_RED=""; E_RESET=""
fi
STEP=0
STEP_TOTAL=0

ui_step()    { STEP=$((STEP + 1)); printf '%s[%d/%d]%s %s\n' "$C_BOLD" "$STEP" "$STEP_TOTAL" "$C_RESET" "$*"; }
ui_detail()  { printf '      %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
ui_heading() { printf '%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }
# Indented line at normal brightness (summary fields)
ui_line()    { printf '      %s\n' "$*"; }
ui_ok()      { printf '%s[+]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
ui_warn()    { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
ui_error()   { printf '%s[-]%s %s\n' "$E_RED" "$E_RESET" "$*" >&2; }
# Prompt label for read -p: read -r -p "$(ui_ask "Continue? [Y/n]: ")" answer
ui_ask()     { printf '%s[?]%s %s' "$E_BOLD" "$E_RESET" "$*"; }
# Show paths under the user's home as ~/...
ui_path() {
    if [[ -n "${USER_HOME:-}" && "$1" == "$USER_HOME/"* ]]; then
        printf '~/%s' "${1#"$USER_HOME"/}"
    else
        printf '%s' "$1"
    fi
}

show_help() {
    echo "dopt $DOPT_VERSION - Directory Optional Package Manager"
    echo "Usage: ./dopt.sh [options]"
    echo ""
    echo "Manifest (Optional):"
    echo "  -m, --manifest <json>   The application manifest recipe configuration file"
    echo "  -a, --app-id <id>       Provide App ID directly if not using a manifest"
    echo "  -s, --symlink-as <name> Command name to link (overrides the manifest's 'symlink_as')"
    echo ""
    echo "Deployment Targets (Choose one. If omitted, dopt offers your recent downloads):"
    echo "  -d, --download          Download using the manifest's default server endpoint"
    echo "  -u, --url <url>         Download using a specific direct link override"
    echo "  -f, --file <path>       Directly deploy from a local archive package file"
    echo "      --sha256 <hash>     Verify the archive's SHA-256 checksum before installing"
    echo ""
    echo "Modifiers:"
    echo "  -g, --global            Install system-wide to /opt (requires sudo)"
    echo "  -c, --cleanup           Delete the downloaded or local archive after a successful setup"
    echo "  -i, --install           Skip confirmation prompts; auto-terminate and relaunch a running app"
    echo "  -v, --version           Show the dopt version"
    echo "  -h, --help              Show this help menu"
    echo ""
    echo "Environment:"
    echo "  NO_COLOR=1              Disable colored output (color is also off when output isn't a terminal)"
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
        ui_error "Invalid $label '$value' ($NAME_RULES)."
        exit 1
    fi
}

manifest_get() {
    jq -r --arg k "$1" '.[$k] // empty' "$MANIFEST"
}

# Sets OWNER_PKG/OWNER_TOOL if a system package owns the directory or a sample of files inside it
package_owner() {
    local samples
    OWNER_PKG=""
    OWNER_TOOL=""
    mapfile -t samples < <({ printf '%s\n' "$1"; find "$1" -maxdepth 3 -type f 2>/dev/null | head -n 20; })
    if command -v rpm >/dev/null 2>&1; then
        # Owned paths print a bare package name; unowned ones print a sentence (contains spaces)
        OWNER_PKG=$(rpm -qf --qf '%{NAME}\n' -- "${samples[@]}" 2>/dev/null | grep -v ' ' | head -n 1 || true)
        [[ -n "$OWNER_PKG" ]] && { OWNER_TOOL="dnf"; return 0; }
    fi
    if command -v dpkg >/dev/null 2>&1; then
        OWNER_PKG=$(dpkg -S -- "${samples[@]}" 2>/dev/null | grep -v '^diversion' | head -n 1 | cut -d: -f1 | cut -d, -f1 || true)
        [[ -n "$OWNER_PKG" ]] && { OWNER_TOOL="apt"; return 0; }
    fi
    return 1
}

# Replace control characters (newlines, tabs, ...) with single spaces
single_line() {
    printf '%s' "$1" | tr '\000-\037\177' ' ' | tr -s ' '
}

# Desktop Entry string value: single line (no injected keys), backslashes escaped
desktop_text() {
    local v
    v=$(single_line "$1")
    printf '%s' "${v//\\/\\\\}"
}

# Desktop Entry Exec program path: always quoted, '%' escaped; refuses characters that need shell escaping
desktop_exec_path() {
    case "$1" in
        *'"'*|*'`'*|*'$'*|*'\'*) return 1 ;;
    esac
    printf '"%s"' "${1//%/%%}"
}

# Shallowest file under $1 (max depth 3) whose name matches pattern $2
find_binary_by_name() {
    find "$1" -maxdepth 3 -type f -iname "$2" -printf '%d\t%p\n' 2>/dev/null | sort -n | head -n 1 | cut -f2- || true
}

# Executable candidates under $1 (relative paths, shallowest first) for the binary picker
list_executables() {
    find "$1" -maxdepth 3 -type f -executable ! -name '*.so' ! -name '*.so.*' \
        ! -name 'chrome-sandbox' ! -name 'crashpad_handler' ! -name 'chrome_crashpad_handler' \
        -printf '%d\t%P\n' 2>/dev/null | sort -n | cut -f2- | head -n 10 || true
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
        -p|--path)     ui_error "-p was removed in 2.0; pass the archive with -f <file>."; exit 1 ;;
        --sha256)
            SHA256_EXPECTED="${2,,}"
            if [[ ! "$SHA256_EXPECTED" =~ ^[0-9a-f]{64}$ ]]; then
                ui_error "--sha256 expects a 64-character hexadecimal SHA-256 checksum."
                exit 1
            fi
            shift 2 ;;
        -v|--version)  echo "dopt $DOPT_VERSION"; exit 0 ;;
        -h|--help)     show_help; exit 0 ;;
        *) ui_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if [[ -n "$MANIFEST" ]]; then
    # Verify JSON parser dependencies exist on host
    if ! command -v jq >/dev/null 2>&1; then
        ui_error "Manifests need 'jq'. Install it with: sudo dnf install jq"
        exit 1
    fi

    if [[ ! -f "$MANIFEST" ]]; then
        ui_error "Manifest not found: $MANIFEST"
        exit 1
    fi
fi

# 2. Secure environment validation hooks & Path Resolution
REAL_USER="${SUDO_USER:-$(id -un)}"
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
# Where an existing system-wide install would live (checked when installing locally)
GLOBAL_OPT_DIR="/opt"
DOPT_TEST_ROOT="${DOPT_TEST_ROOT:-}"

if [[ -n "$DOPT_TEST_ROOT" && "$GLOBAL_INSTALL" = true ]]; then
    ui_error "DOPT_TEST_ROOT (test mode) can't be combined with --global."
    exit 1
fi

if [ "$GLOBAL_INSTALL" = true ]; then
    if [[ $EUID -ne 0 ]]; then
        ui_error "--global installs system-wide and needs root. Re-run with sudo."
        exit 1
    fi
    OPT_DIR="/opt"
    BIN_LINK_DIR="/usr/local/bin"
    DESKTOP_DIR="/usr/share/applications"
else
    if [[ $EUID -eq 0 ]]; then
        ui_error "Don't run a local install as root. Re-run without sudo, or add --global for a system-wide install."
        exit 1
    fi
    OPT_DIR="$USER_HOME/.local/opt"
    BIN_LINK_DIR="$USER_HOME/.local/bin"
    DESKTOP_DIR="$USER_HOME/.local/share/applications"
    # Test mode (tests/run.sh): keep every write inside a throwaway root instead of the real home
    if [[ -n "$DOPT_TEST_ROOT" ]]; then
        OPT_DIR="$DOPT_TEST_ROOT/opt"
        BIN_LINK_DIR="$DOPT_TEST_ROOT/bin"
        DESKTOP_DIR="$DOPT_TEST_ROOT/applications"
        GLOBAL_OPT_DIR="$DOPT_TEST_ROOT/global-opt"
    fi

    mkdir -p "$OPT_DIR" "$BIN_LINK_DIR" "$DESKTOP_DIR"
fi

# Registry of dopt installs: one small file per app, kept outside the app folders
REGISTRY_DIR="$OPT_DIR/.dopt"

# Identity of a folder: inode + birth time, unchanged by renames but new if the folder is recreated
folder_identity() {
    stat -c '%i:%W' -- "$1" 2>/dev/null || true
}

registry_get() {
    sed -n "s/^$2=//p" "$REGISTRY_DIR/$1" 2>/dev/null | head -n 1 || true
}

# 3. Resolve App ID
if [[ -n "$MANIFEST" && -f "$MANIFEST" ]]; then
    APP_ID=$(manifest_get app_id)
    [[ -z "$APP_ID" ]] && { ui_error "The manifest is missing the required field 'app_id'."; exit 1; }
else
    APP_ID="${APP_ID_CLI:-}"
    if [[ -z "$APP_ID" ]]; then
        ui_heading "Interactive setup"
        ui_detail "Tip: type '?' to list installed apps."
        while true; do
            read -r -p "$(ui_ask "Enter App ID (e.g. com.example.app): ")" APP_ID
            if [[ "$APP_ID" == "?" ]]; then
                echo -e "\n--- Installed by dopt in $OPT_DIR ---"
                found_any=false
                for entry in "$REGISTRY_DIR"/*; do
                    [[ -f "$entry" ]] || continue
                    found_any=true
                    entry_id=$(basename "$entry")
                    if [[ -d "$OPT_DIR/$entry_id" ]]; then
                        echo "- $entry_id"
                    else
                        echo "- $entry_id (folder missing)"
                    fi
                done
                [[ "$found_any" = false ]] && echo "  (none registered yet)"
                other_dirs=()
                for dir in "$OPT_DIR"/*/; do
                    [[ -d "$dir" ]] || continue
                    dir_id=$(basename "$dir")
                    [[ -f "$REGISTRY_DIR/$dir_id" ]] || other_dirs+=("$dir_id")
                done
                if [[ ${#other_dirs[@]} -gt 0 ]]; then
                    echo "--- Other folders (not registered; older dopt installs or manual) ---"
                    printf -- '- %s\n' "${other_dirs[@]}"
                fi
                echo -e "--------------------------------------\n"
            else
                break
            fi
        done
    fi
    [[ -z "$APP_ID" ]] && { ui_error "An App ID is required."; exit 1; }
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

if [ "$GLOBAL_INSTALL" = false ] && [[ -d "$GLOBAL_OPT_DIR/$APP_ID" ]]; then
    echo ""
    ui_warn "Found existing system-wide installation of $APP_ID at $GLOBAL_OPT_DIR/$APP_ID."
    echo "    1) Update the system-wide install (re-runs with sudo)"
    echo "    2) Install a separate local copy"
    echo "    3) Abort"
    read -r -p "$(ui_ask "Choose an action [1-3]: ")" action_res
    case "$action_res" in
        1)
            ui_detail "Re-running with sudo..."
            SELF_PATH=$(readlink -f "$0")
            if [[ -z "$MANIFEST" && -z "${APP_ID_CLI:-}" ]]; then
                exec sudo "$SELF_PATH" -g "${ORIG_ARGS[@]}" -a "$APP_ID"
            else
                exec sudo "$SELF_PATH" -g "${ORIG_ARGS[@]}"
            fi
            ;;
        2)
            read -r -p "$(ui_ask "Add '-local' to the App ID and name, so this copy doesn't hide the system-wide app in your menu? [Y/n]: ")" rename_res
            if [[ ! "${rename_res,,}" =~ ^(no|n) ]]; then
                GLOBAL_DESKTOP="/usr/share/applications/${APP_ID}.desktop"
                if [[ -f "$GLOBAL_DESKTOP" ]]; then
                    GLOBAL_NAME=$(grep "^Name=" "$GLOBAL_DESKTOP" | cut -d= -f2- || true)
                    [[ -n "$GLOBAL_NAME" ]] && DEF_APP_NAME="$GLOBAL_NAME (Local)"
                fi
                APP_ID="${APP_ID}-local"
                validate_name "App ID" "$APP_ID"
                APPEND_LOCAL_NAME=true
                ui_detail "App ID is now $APP_ID"
            fi
            ;;
        *)
            ui_error "Deployment aborted."
            exit 1
            ;;
    esac
fi

# 3.5 Source Validation & Recovery
expand_home() {
    if [[ "$1" == "~"* ]]; then
        printf '%s' "${1/\~/$USER_HOME}"
    else
        printf '%s' "$1"
    fi
}

# The real user's downloads folder (XDG, so renamed/translated folders work)
downloads_dir() {
    local dir=""
    if [[ -n "$DOPT_TEST_ROOT" ]]; then
        echo "$DOPT_TEST_ROOT/Downloads"
        return
    fi
    if command -v xdg-user-dir >/dev/null 2>&1; then
        if [[ $EUID -eq 0 ]]; then
            dir=$(sudo -u "$REAL_USER" xdg-user-dir DOWNLOAD 2>/dev/null || true)
        else
            dir=$(xdg-user-dir DOWNLOAD 2>/dev/null || true)
        fi
    fi
    # xdg-user-dir falls back to $HOME when no downloads folder is configured
    if [[ -z "$dir" || "$dir" == "$USER_HOME" || "$dir" == "$HOME" ]]; then
        dir="$USER_HOME/Downloads"
    fi
    echo "$dir"
}

# "2 days ago" style age for an epoch timestamp
age_text() {
    local secs=$(( $(date +%s) - ${1%.*} ))
    (( secs < 0 )) && secs=0
    if (( secs < 3600 )); then echo "$(( secs / 60 )) min ago"
    elif (( secs < 86400 )); then echo "$(( secs / 3600 )) h ago"
    elif (( secs < 86400 * 14 )); then echo "$(( secs / 86400 )) days ago"
    else echo "$(( secs / 604800 )) weeks ago"
    fi
}

if [ "$DOWNLOAD" = false ] && [[ -z "$FILE_PATH" ]]; then
    if [ "$FORCE_INSTALL" = true ]; then
        ui_error "No archive given. Pass -f <file>, -u <url> or -d."
        exit 1
    fi

    DL_DIR=$(downloads_dir)
    RECENT_FILES=()
    RECENT_TIMES=()
    if [[ -d "$DL_DIR" ]]; then
        while IFS=$'\t' read -r mtime path; do
            RECENT_TIMES+=("$mtime")
            RECENT_FILES+=("$path")
        done < <(find "$DL_DIR" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.tgz' \) -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -n 5)
    fi

    echo ""
    ui_heading "No archive given."
    if [[ ${#RECENT_FILES[@]} -gt 0 ]]; then
        echo "    Recent downloads in $DL_DIR:"
        for i in "${!RECENT_FILES[@]}"; do
            printf '    %d) %s  (%s)\n' "$((i + 1))" "$(basename "${RECENT_FILES[$i]}")" "$(age_text "${RECENT_TIMES[$i]}")"
        done
    fi
    echo "    u) Enter a URL   p) Enter a path   a) Abort"
    if [[ ${#RECENT_FILES[@]} -gt 0 ]]; then
        read -r -p "$(ui_ask "Choose [1-${#RECENT_FILES[@]}/u/p/a]: ")" source_res
    else
        read -r -p "$(ui_ask "Choose [u/p/a]: ")" source_res
    fi

    if [[ "$source_res" =~ ^[0-9]+$ ]] && (( source_res >= 1 && source_res <= ${#RECENT_FILES[@]} )); then
        FILE_PATH="${RECENT_FILES[$((source_res - 1))]}"
        ui_detail "Using $(ui_path "$FILE_PATH")"
    else
        case "${source_res,,}" in
            u)
                read -r -p "$(ui_ask "Enter full URL (e.g. https://...): ")" CUSTOM_URL
                [[ -z "$CUSTOM_URL" ]] && { ui_error "The URL can't be empty."; exit 1; }
                DOWNLOAD=true
                ;;
            p)
                # -e enables Tab completion for the path
                read -r -e -p "$(ui_ask "Enter the archive path: ")" FILE_PATH
                # Paths pasted from a file manager often come wrapped in quotes
                if [[ "$FILE_PATH" =~ ^\'(.*)\'$ || "$FILE_PATH" =~ ^\"(.*)\"$ ]]; then
                    FILE_PATH="${BASH_REMATCH[1]}"
                fi
                [[ -z "$FILE_PATH" ]] && { ui_error "The path can't be empty."; exit 1; }
                ;;
            *)
                ui_error "Deployment aborted."
                exit 1
                ;;
        esac
    fi
fi

if [[ -n "$FILE_PATH" ]]; then
    FILE_PATH=$(expand_home "$FILE_PATH")
    if [[ ! -f "$FILE_PATH" ]]; then
        ui_error "Archive not found: $FILE_PATH"; exit 1
    fi
fi

# Defaults from the previous installation: only look where dopt itself writes
DESKTOP_FILE="$DESKTOP_DIR/${APP_ID}.desktop"
if [[ -d "$OPT_DIR/$APP_ID" ]]; then
    EXISTING_LINK=$(find "$BIN_LINK_DIR" -maxdepth 1 -type l -lname "$OPT_DIR/$APP_ID/*" 2>/dev/null | head -n 1 || true)
    if [[ -n "$EXISTING_LINK" ]]; then
        DEF_SYMLINK_NAME=$(basename "$EXISTING_LINK")
        # Path relative to the install dir (e.g. bin/app), so nested binaries are found again
        OLD_TARGET=$(readlink -- "$EXISTING_LINK")
        DEF_BINARY_PATTERN="${OLD_TARGET#"$OPT_DIR/$APP_ID/"}"
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
        ui_error "The manifest must define 'binary_path' or 'binary_pattern'."
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
    [[ -d "$OPT_DIR/$APP_ID" ]] && ui_detail "Existing install found; its settings are the defaults."
    
    read -r -p "$(ui_ask "Enter Application Name [${DEF_APP_NAME:-$APP_ID}]: ")" APP_NAME
    APP_NAME=${APP_NAME:-${DEF_APP_NAME:-$APP_ID}}
    
    if [[ -n "$SYMLINK_CLI" ]]; then
        SYMLINK_NAME="$SYMLINK_CLI"
    else
        read -r -p "$(ui_ask "Enter executable symlink name [${DEF_SYMLINK_NAME:-$APP_ID}]: ")" SYMLINK_NAME
        SYMLINK_NAME=${SYMLINK_NAME:-${DEF_SYMLINK_NAME:-$APP_ID}}
    fi
    
    cli_prompt_def="[y/N]"
    [[ "${DEF_CLI_ANS,,}" == "y" ]] && cli_prompt_def="[Y/n]"
    read -r -p "$(ui_ask "Is this a CLI-only application? $cli_prompt_def: ")" cli_ans
    cli_ans=${cli_ans:-${DEF_CLI_ANS:-n}}
    if [[ "${cli_ans,,}" =~ ^(yes|y) ]]; then
        CLI_ONLY="true"
    else
        CLI_ONLY="false"
    fi
    
    APP_COMMENT=""

    read -r -p "$(ui_ask "Enter target binary name or relative path (e.g. bin/app) [${DEF_BINARY_PATTERN:-$SYMLINK_NAME}]: ")" BINARY_PATTERN
    BINARY_PATTERN=${BINARY_PATTERN:-${DEF_BINARY_PATTERN:-$SYMLINK_NAME}}
    BINARY_PATH=""
    if [[ "$BINARY_PATTERN" == */* ]]; then
        BINARY_PATH="$BINARY_PATTERN"
        BINARY_PATTERN=""
    fi
    
    icon_prompt_def="(leave blank to auto-detect)"
    [[ -n "$DEF_ICON_MANIFEST" ]] && icon_prompt_def="[$DEF_ICON_MANIFEST]"
    read -r -p "$(ui_ask "Enter icon file path/name $icon_prompt_def: ")" ICON_PATH_MANIFEST
    ICON_PATH_MANIFEST=${ICON_PATH_MANIFEST:-$DEF_ICON_MANIFEST}
    
    read -r -p "$(ui_ask "Enter Desktop Category (e.g. Utility;, Development;, Game;) [${DEF_CATEGORIES:-Utility;}]: ")" APP_CATEGORIES
    APP_CATEGORIES=${APP_CATEGORIES:-${DEF_CATEGORIES:-Utility;}}
    [[ -n "$APP_CATEGORIES" && "$APP_CATEGORIES" != *";" ]] && APP_CATEGORIES="${APP_CATEGORIES};"
    
    EXEC_FLAGS=""
fi

validate_name "symlink name" "$SYMLINK_NAME"

APP_NAME=$(single_line "$APP_NAME")
APP_COMMENT=$(single_line "${APP_COMMENT:-}")

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
        ui_error "Safety abort: refusing to modify $target (outside dopt's folder $OPT_DIR)."
        exit 1
    fi
}

# True if $1 resolves to a path inside $2/
path_is_inside() {
    local resolved
    resolved=$(readlink -m -- "$1")
    [[ "$resolved" == "$(readlink -m -- "$2")/"* ]]
}

# 4. Ownership: never touch package-managed folders; only upgrade registered dopt installs without asking
STEP_TOTAL=3
[ "$DOWNLOAD" = true ] && STEP_TOTAL=$((STEP_TOTAL + 1))
[[ "$CLI_ONLY" != "true" ]] && STEP_TOTAL=$((STEP_TOTAL + 1))
WAS_INSTALLED=false
[[ -d "$INSTALL_DIR" ]] && WAS_INSTALLED=true
ui_step "Checking $APP_NAME..."
if [[ -d "$INSTALL_DIR" ]] && package_owner "$INSTALL_DIR"; then
    ui_error "$INSTALL_DIR belongs to the system package '$OWNER_PKG'. dopt won't modify package-managed files."
    echo "      To use the tarball version, install it alongside with a different App ID," >&2
    echo "      or remove the package first: sudo $OWNER_TOOL remove $OWNER_PKG" >&2
    exit 1
fi

REGISTERED_ID=$(registry_get "$APP_ID" folder_id)
if [[ -d "$INSTALL_DIR" && ( -z "$REGISTERED_ID" || "$REGISTERED_ID" != "$(folder_identity "$INSTALL_DIR")" ) ]]; then
    if [[ -n "$REGISTERED_ID" ]]; then
        ui_warn "$(ui_path "$INSTALL_DIR") was replaced or recreated since dopt installed it."
    else
        ui_warn "$(ui_path "$INSTALL_DIR") exists but isn't registered as a dopt install."
        ui_detail "Installs made by older versions of dopt ask this once."
    fi
    entry_count=$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    ui_detail "Size: $(du -sh -- "$INSTALL_DIR" 2>/dev/null | cut -f1), $entry_count top-level entries:"
    find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -printf '        %f\n' 2>/dev/null | sort | head -n 8 || true
    [[ "$entry_count" -gt 8 ]] && echo "        ..."
    if [ "$FORCE_INSTALL" = true ]; then
        ui_error "Refusing to replace it in forced (-i) mode. Re-run without -i to confirm."
        exit 1
    fi
    read -r -p "$(ui_ask "Replace it with the new version? [y/N]: ")" replace_res
    if [[ ! "${replace_res,,}" =~ ^(yes|y)$ ]]; then
        ui_error "Deployment aborted. $(ui_path "$INSTALL_DIR") was not modified."
        exit 0
    fi
fi

# 4.5 Make sure the command name doesn't belong to something dopt didn't install
abort_name_clash() {
    if [ "$FORCE_INSTALL" = true ]; then
        ui_error "Can't ask for a different command name in forced (-i) mode."
    fi
    ui_error "Deployment aborted. Re-run with -s <name> to use a different command name."
    exit 1
}

prompt_new_symlink_name() {
    local new_name
    while true; do
        read -r -p "$(ui_ask "Enter a different command name: ")" new_name
        if [[ -z "$new_name" ]]; then
            ui_error "Name cannot be empty."
        elif ! is_valid_name "$new_name"; then
            ui_error "Invalid name '$new_name' ($NAME_RULES)."
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
        ui_warn "$(ui_path "$BIN_LINK") already exists and wasn't installed by dopt for $APP_ID."
        [ "$FORCE_INSTALL" = true ] && abort_name_clash
        echo "    1) Choose a different command name"
        echo "    2) Abort"
        read -r -p "$(ui_ask "Choose an action [1-2] (default 1): ")" clash_res
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
            ui_warn "'$SYMLINK_NAME' also exists at $(ui_path "$EXISTING_BIN") (another install of this app). Whichever comes first in PATH runs."
        else
            ui_warn "The command '$SYMLINK_NAME' already exists at $(ui_path "$EXISTING_BIN") and wasn't installed by dopt."
            [ "$FORCE_INSTALL" = true ] && abort_name_clash
            echo "    1) Choose a different command name"
            echo "    2) Continue anyway (which '$SYMLINK_NAME' runs will depend on PATH order)"
            echo "    3) Abort"
            read -r -p "$(ui_ask "Choose an action [1-3] (default 1): ")" clash_res
            case "${clash_res:-1}" in
                1) prompt_new_symlink_name; continue ;;
                2) ui_warn "Continuing: $(ui_path "$BIN_LINK") will coexist with $(ui_path "$EXISTING_BIN")." ;;
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
    ui_detail "Tip: the manifest's 'symlink_as' doesn't match the name you chose. Update it, or pass -s \"$SYMLINK_NAME\" next time."
fi

# The desktop shortcut quotes the command path; refuse paths that would need shell escaping
if [[ "$CLI_ONLY" != "true" ]] && ! desktop_exec_path "$BIN_LINK" >/dev/null; then
    ui_error "The command path $BIN_LINK contains characters (\" \` \$ \\) that can't be used in a desktop shortcut."
    exit 1
fi

if [[ -d "$INSTALL_DIR" ]]; then
    ui_detail "Updating the existing install at $(ui_path "$INSTALL_DIR")"
elif [ "$FORCE_INSTALL" = false ]; then
    read -r -p "$(ui_ask "Install $APP_NAME to $(ui_path "$INSTALL_DIR")? [Y/n]: ")" inst_res
    if [[ "${inst_res,,}" =~ ^(no|n) ]]; then
        ui_error "Deployment aborted."
        exit 0
    fi
fi

# 5. Target Architecture Resolution and Source Acquisition
TMP_DIR=$(mktemp -d -t dopt-workspace-XXXXXXXX)
# Move the downloaded archive into the current directory without overwriting anything.
# Prints the saved path; fails (saving nothing) if the archive isn't a readable tarball.
preserve_download() {
    local name stem ext dest n safe_name='^[A-Za-z0-9._ +-]+$'
    [[ -f "${TARBALL:-}" ]] && tar -tzf "$TARBALL" >/dev/null 2>&1 || return 1

    name="${DOWNLOAD_URL:-}"; name="${name%%[?#]*}"
    name=$(basename -- "$name")
    name="${name//%20/ }"
    if [[ -z "$name" || "$name" == download* || "$name" == .* || ! "$name" =~ $safe_name ||
          ( "$name" != *.tar.gz && "$name" != *.tgz ) ]]; then
        name="${APP_ID}-linux.tar.gz"
    fi

    if [[ "$name" == *.tar.gz ]]; then
        stem="${name%.tar.gz}"; ext=".tar.gz"
    else
        stem="${name%.tgz}"; ext=".tgz"
    fi
    # Reuse an identical copy (name, name-1, name-2, ...); otherwise take the first free name
    dest="$(pwd)/$name"
    n=0
    while [[ -e "$dest" ]]; do
        if cmp -s -- "$TARBALL" "$dest"; then
            echo "$dest"
            return 0
        fi
        n=$((n + 1))
        dest="$(pwd)/${stem}-${n}${ext}"
    done

    mv -- "$TARBALL" "$dest" || return 1
    if [[ -n "${SUDO_USER:-}" ]]; then chown -- "${SUDO_USER}:" "$dest" 2>/dev/null || true; fi
    echo "$dest"
}

print_resume_hint() {
    local sudo_prefix="" sha_hint=""
    [[ -n "$SHA256_EXPECTED" ]] && sha_hint=" --sha256 $SHA256_EXPECTED"
    [[ "$GLOBAL_INSTALL" = true ]] && sudo_prefix="sudo "
    ui_warn "To apply this update later without re-downloading, run:"
    if [[ -n "${MANIFEST:-}" && -f "${MANIFEST:-}" ]]; then
        echo "    ${sudo_prefix}./dopt.sh -m \"$MANIFEST\" -f \"$1\"${SYMLINK_HINT:-}${sha_hint}"
    else
        echo "    ${sudo_prefix}./dopt.sh -a \"$APP_ID\" -f \"$1\"${SYMLINK_HINT:-}${sha_hint}"
    fi
}

cleanup_workspace() {
    local exit_code=$? saved
    # Roll back an interrupted swap and drop any half-built staging copy
    if [[ -d "$BACKUP_DIR" && ! -e "$INSTALL_DIR" ]]; then
        if mv -- "$BACKUP_DIR" "$INSTALL_DIR" 2>/dev/null; then
            ui_warn "Update failed. The previous version was restored at $(ui_path "$INSTALL_DIR")"
        fi
    fi
    [[ -e "$STAGE_DIR" ]] && rm -rf -- "$STAGE_DIR"
    if [[ $exit_code -ne 0 && "$DOWNLOAD" = true && "$CLEANUP" = false ]]; then
        if saved=$(preserve_download); then
            ui_detail "The downloaded archive was kept at $(ui_path "$saved")"
            print_resume_hint "$saved"
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
    *) ui_error "Unsupported processor architecture: $ARCH_RAW"; exit 1 ;;
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
        ui_error "No download URL. Pass -u <url>, or add default_url_x64/default_url_arm64 to the manifest."
        exit 1
    fi
    
    TARBALL="$TMP_DIR/source_package.tar.gz"
    ui_step "Downloading..."
    # A single progress bar on a terminal; silent (errors only) in logs and pipes
    if [[ -t 2 ]]; then
        CURL_PROGRESS=(--progress-bar)
    else
        CURL_PROGRESS=(-sS)
    fi
    if ! curl -fL "${CURL_PROGRESS[@]}" -o "$TARBALL" "$DOWNLOAD_URL"; then
        rm -f -- "$TARBALL"
        ui_error "Download failed. Check the URL and your connection: $DOWNLOAD_URL"
        exit 1
    fi
else
    TARBALL="$FILE_PATH"
fi

ui_step "Unpacking..."
# Optional integrity check (--sha256), before anything is extracted
if [[ -n "$SHA256_EXPECTED" ]]; then
    SHA256_ACTUAL=$(sha256sum -- "$TARBALL" | cut -d' ' -f1)
    if [[ "$SHA256_ACTUAL" != "$SHA256_EXPECTED" ]]; then
        # A mismatched download must never be kept or offered for resuming
        [ "$DOWNLOAD" = true ] && rm -f -- "$TARBALL"
        ui_error "SHA-256 mismatch. The archive was not installed."
        echo "      Expected: $SHA256_EXPECTED" >&2
        echo "      Actual:   $SHA256_ACTUAL" >&2
        exit 1
    fi
    ui_detail "SHA-256 verified"
fi

# 6. Unpack and Parse Sandbox Interior
EXTRACT_DIR="$TMP_DIR/extract"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$TARBALL" -C "$EXTRACT_DIR"

# A single top-level folder is a wrapper (app-1.2/...): install its contents. Otherwise install everything.
mapfile -t TOP_ENTRIES < <(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1)
if [[ ${#TOP_ENTRIES[@]} -eq 0 ]]; then
    ui_error "The archive is empty."
    exit 1
elif [[ ${#TOP_ENTRIES[@]} -eq 1 && -d "${TOP_ENTRIES[0]}" && ! -L "${TOP_ENTRIES[0]}" ]]; then
    EXTRACTED_FOLDER="${TOP_ENTRIES[0]}"
else
    EXTRACTED_FOLDER="$EXTRACT_DIR"
fi

# 7. Stage the new version next to the live one, so the swap is a pair of renames
if [[ ! -w "$OPT_DIR" ]]; then
    ui_error "Permission denied: you can't write to $OPT_DIR."
    if [[ "$OPT_DIR" == "/opt" ]]; then
        echo "      This is a system-wide install. Run dopt with sudo and --global." >&2
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

mkdir -p "$STAGE_DIR"
cp -R "$EXTRACTED_FOLDER"/. "$STAGE_DIR/"

if [[ -n "$BINARY_PATH" ]]; then
    STAGED_BINARY="$STAGE_DIR/$BINARY_PATH"
else
    STAGED_BINARY=$(find_binary_by_name "$STAGE_DIR" "$BINARY_PATTERN")
    [[ -z "$STAGED_BINARY" ]] && STAGED_BINARY=$(find "$STAGE_DIR" -maxdepth 1 -type f -executable ! -name "chrome-sandbox" ! -name "crashpad_handler" | head -n 1)
fi

staged_binary_ok() {
    [[ -n "$STAGED_BINARY" && -f "$STAGED_BINARY" ]] && path_is_inside "$STAGED_BINARY" "$STAGE_DIR"
}

if ! staged_binary_ok; then
    mapfile -t CANDIDATES < <(list_executables "$STAGE_DIR")
    ui_warn "Couldn't find the binary '${BINARY_PATH:-$BINARY_PATTERN}' in the archive."
    if [[ -z "$MANIFEST" && "$FORCE_INSTALL" = false && ${#CANDIDATES[@]} -gt 0 ]]; then
        ui_detail "Executables found in the package:"
        for i in "${!CANDIDATES[@]}"; do
            echo "        $((i + 1))) ${CANDIDATES[$i]}"
        done
        read -r -p "$(ui_ask "Pick the binary to link [1-${#CANDIDATES[@]}], or press Enter to abort: ")" pick_res
        if [[ "$pick_res" =~ ^[0-9]+$ ]] && (( pick_res >= 1 && pick_res <= ${#CANDIDATES[@]} )); then
            STAGED_BINARY="$STAGE_DIR/${CANDIDATES[$((pick_res - 1))]}"
        else
            STAGED_BINARY=""
        fi
    elif [[ ${#CANDIDATES[@]} -gt 0 ]]; then
        if [[ -n "$MANIFEST" ]]; then
            ui_detail "Executables found in the package (use one as 'binary_path' in the manifest):"
        else
            ui_detail "Executables found in the package (enter one as the binary path):"
        fi
        printf '        %s\n' "${CANDIDATES[@]}"
    fi
fi

if ! staged_binary_ok; then
    ui_error "Couldn't find the app's executable in the archive. Nothing was changed."
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

ui_step "Installing..."
mapfile -t APP_PIDS < <(find_app_pids)
if [[ ${#APP_PIDS[@]} -gt 0 ]]; then
    if [ "$FORCE_INSTALL" = true ]; then
        ui_detail "Stopping the running $APP_NAME (-i)..."
        terminate_app "${APP_PIDS[@]}"
        if [[ "$CLI_ONLY" != "true" ]]; then RESTART_REQD=true; fi
    else
        ui_warn "$APP_NAME is running."
        read -r -p "$(ui_ask "Stop it to install the update? [Y/n]: ")" run_res
        if [[ ! "${run_res,,}" =~ ^(no|n) ]]; then
            terminate_app "${APP_PIDS[@]}"
            if [[ "$CLI_ONLY" != "true" ]]; then RESTART_REQD=true; fi
        else
            ui_warn "Update canceled to keep $APP_NAME running."
            RESUME_FILE=""
            if [ "$DOWNLOAD" = true ]; then
                if [ "$CLEANUP" = false ] && RESUME_FILE=$(preserve_download); then
                    ui_detail "The downloaded archive was kept at $(ui_path "$RESUME_FILE")"
                fi
            else
                RESUME_FILE="$TARBALL"
            fi

            if [[ -n "$RESUME_FILE" ]]; then
                echo ""
                print_resume_hint "$RESUME_FILE"
            fi
            exit 0
        fi
    fi
fi

# Swap: live -> backup, staged -> live, then drop the backup. The exit trap restores the backup on failure.
assert_managed_dir "$INSTALL_DIR"
if [[ -e "$INSTALL_DIR" ]]; then
    mv -- "$INSTALL_DIR" "$BACKUP_DIR"
fi
mv -- "$STAGE_DIR" "$INSTALL_DIR"
rm -rf -- "$BACKUP_DIR"

# Register the install (identity of the folder now in place)
mkdir -p "$REGISTRY_DIR"
printf 'app_id=%s\nfolder_id=%s\ninstalled=%s\n' "$APP_ID" "$(folder_identity "$INSTALL_DIR")" "$(date -Is)" > "$REGISTRY_DIR/$APP_ID"

REAL_BINARY="$INSTALL_DIR/$BINARY_REL_PATH"

if [[ -n "${DEF_SYMLINK_NAME:-}" && "$DEF_SYMLINK_NAME" != "$SYMLINK_NAME" ]]; then
    OLD_BIN_LINK="$BIN_LINK_DIR/$DEF_SYMLINK_NAME"
    if [[ -L "$OLD_BIN_LINK" ]] && path_is_inside "$(readlink -- "$OLD_BIN_LINK")" "$INSTALL_DIR"; then
        ui_detail "Removed the old command link '$DEF_SYMLINK_NAME'"
        rm -f -- "$OLD_BIN_LINK"
    fi
fi

chmod +x "$REAL_BINARY"
ln -sfn "$REAL_BINARY" "$BIN_LINK"

# 8. Dynamic Linux Desktop Icon Integration Layout
if [[ "$CLI_ONLY" != "true" ]]; then
    ui_step "Creating menu shortcut..."
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

    DESKTOP_EXEC=$(desktop_exec_path "$BIN_LINK")
    DESKTOP_FLAGS=$(desktop_text "${EXEC_FLAGS:-}")
    DESKTOP_COMMENT=$(desktop_text "${APP_COMMENT:-}")
    {
        echo "[Desktop Entry]"
        echo "Version=1.0"
        echo "Type=Application"
        echo "Name=$(desktop_text "$APP_NAME")"
        [[ -n "$DESKTOP_COMMENT" ]] && echo "Comment=$DESKTOP_COMMENT"
        echo "Exec=${DESKTOP_EXEC}${DESKTOP_FLAGS:+ $DESKTOP_FLAGS}"
        echo "Icon=$(desktop_text "${ICON_PATH:-system-run}")"
        echo "Terminal=false"
        echo "Categories=$(desktop_text "${APP_CATEGORIES:-Utility;}")"
        echo "StartupWMClass=$(desktop_text "$(basename "$REAL_BINARY")")"
    } > "$DESKTOP_FILE"

    if command -v desktop-file-validate >/dev/null 2>&1; then
        VALIDATE_OUT=$(desktop-file-validate "$DESKTOP_FILE" 2>&1 || true)
        if [[ -n "$VALIDATE_OUT" ]]; then
            ui_warn "desktop-file-validate reported:"
            sed 's/^/      /' <<< "$VALIDATE_OUT"
        fi
    fi
else
    if [[ -f "$DESKTOP_FILE" ]]; then
        ui_detail "Removed the old menu shortcut (the app is CLI-only now)"
        rm -f -- "$DESKTOP_FILE"
    fi
fi

# 9. Post-Execution cleanup hooks
ARCHIVE_NOTE=""
if [ "$DOWNLOAD" = true ]; then
    if [ "$CLEANUP" = true ]; then
        ARCHIVE_NOTE="not kept (-c)"
    elif KEPT_FILE=$(preserve_download); then
        ARCHIVE_NOTE="kept at $(ui_path "$KEPT_FILE")"
    fi
elif [ "$CLEANUP" = true ] && [[ -f "$TARBALL" ]]; then
    # Local archive (-f, typed or picked): ask before deleting the user's file, unless -i
    del_res="y"
    if [ "$FORCE_INSTALL" = false ]; then
        read -r -p "$(ui_ask "Delete the archive $(ui_path "$TARBALL")? [Y/n]: ")" del_res
    fi
    if [[ ! "${del_res,,}" =~ ^(no|n) ]]; then
        rm -f -- "$TARBALL"
        ARCHIVE_NOTE="deleted ($(ui_path "$TARBALL"))"
    else
        ARCHIVE_NOTE="kept at $(ui_path "$TARBALL")"
    fi
fi

# 10. Environment variables reload check for UI relaunch mapping
# Start the app in the background as the real user, with their graphical session environment
launch_app() {
    local launch_env=(env DISPLAY="${DISPLAY:-:0}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")")
    if [[ $EUID -eq 0 ]]; then
        sudo -u "$REAL_USER" "${launch_env[@]}" nohup "$BIN_LINK" > /dev/null 2>&1 &
    else
        "${launch_env[@]}" nohup "$BIN_LINK" > /dev/null 2>&1 &
    fi
}

# Summary of where everything went
echo ""
if [ "$WAS_INSTALLED" = true ]; then
    ui_ok "$APP_NAME updated"
else
    ui_ok "$APP_NAME installed"
fi
ui_line "Location   $(ui_path "$INSTALL_DIR")  ($(du -sh -- "$INSTALL_DIR" 2>/dev/null | cut -f1))"
if [ "$GLOBAL_INSTALL" = false ] && [[ ":${PATH}:" != *":$BIN_LINK_DIR:"* ]]; then
    ui_line "Command    $SYMLINK_NAME  (note: $(ui_path "$BIN_LINK_DIR") isn't on your PATH)"
else
    ui_line "Command    $SYMLINK_NAME"
fi
if [[ "$CLI_ONLY" != "true" ]]; then
    ui_line "Shortcut   $APP_NAME"
else
    ui_line "Shortcut   none (CLI-only)"
fi
[[ -n "$ARCHIVE_NOTE" ]] && ui_line "Archive    $ARCHIVE_NOTE"

if [[ "$CLI_ONLY" != "true" ]]; then
    if [ "$FORCE_INSTALL" = true ]; then
        if [ "$RESTART_REQD" = true ]; then
            launch_app
            ui_ok "Relaunched $APP_NAME"
        fi
    else
        echo ""
        read -r -p "$(ui_ask "Launch $APP_NAME now? [Y/n]: ")" launch_ans
        if [[ ! "${launch_ans,,}" =~ ^(no|n) ]]; then
            launch_app
            ui_ok "Launched $APP_NAME"
        fi
    fi
fi