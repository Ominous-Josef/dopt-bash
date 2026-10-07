#!/usr/bin/env bash
# dopt test suite.
# Runs dopt.sh against a throwaway root via DOPT_TEST_ROOT, so it never touches the real ~/.local.
# Usage: ./tests/run.sh

set -u

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
DOPT="$REPO_DIR/dopt.sh"
WORK=$(mktemp -d -t dopt-tests-XXXXXXXX)
export DOPT_TEST_ROOT="$WORK/root"

APP="com.dopt.selftest"
OPT="$DOPT_TEST_ROOT/opt"
BIN="$DOPT_TEST_ROOT/bin"
APPS="$DOPT_TEST_ROOT/applications"
DL="$DOPT_TEST_ROOT/Downloads"
INST="$OPT/$APP"
REG="$OPT/.dopt/$APP"
DESK="$APPS/$APP.desktop"
CWD="$WORK/cwd"

REAL_HOME_APP="$HOME/.local/opt/$APP"
REAL_HOME_APP_EXISTED=false
[[ -e "$REAL_HOME_APP" ]] && REAL_HOME_APP_EXISTED=true

PASS=0
FAIL=0
SKIP=0
RC=0
SERVER_PID=""
BG_PIDS=()

cleanup() {
    local pid
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
    for pid in "${BG_PIDS[@]}"; do pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; done
    rm -rf -- "$WORK"
}
trap cleanup EXIT

section() { echo; echo "== $1"; }

check() {
    local desc="$1"
    shift
    if "$@"; then
        PASS=$((PASS + 1)); echo "  PASS  $desc"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL  $desc"
        echo "        --- last dopt output ---"
        tail -n 8 "$WORK/out" 2>/dev/null | sed 's/^/        /'
    fi
}

skip() { SKIP=$((SKIP + 1)); echo "  SKIP  $1"; }

# run "<answers>" <dopt args...>: answers are fed on stdin (printf %b), output goes to $WORK/out, exit code to RC
run() {
    local answers="$1"
    shift
    printf '%b' "$answers" | (cd "$CWD" && "$DOPT" "$@") > "$WORK/out" 2>&1
    RC=$?
}

ok() { [[ $RC -eq 0 ]]; }
failed() { [[ $RC -ne 0 ]]; }
out_has() { grep -qF -- "$1" "$WORK/out"; }
out_lacks() { ! grep -qF -- "$1" "$WORK/out"; }
version_is() { [[ "$(cat "$INST/VERSION" 2>/dev/null)" == "$1" ]]; }
link_to() { [[ "$(readlink "$BIN/$1" 2>/dev/null)" == "$2" ]]; }
file_count() { find "$1" -maxdepth 1 -type f | wc -l; }
failed_with() { [[ $RC -ne 0 ]] && out_has "$1"; }
# Alive and not a zombie
is_alive() { local st; st=$(ps -o stat= -p "$1" 2>/dev/null); [[ -n "$st" && "$st" != Z* ]]; }
not_alive() { ! is_alive "$1"; }

# ---------- fixtures ----------
mkdir -p "$CWD" "$WORK/pkg" "$WORK/srv"

# mkpkg <out.tar.gz> <version> <layout: wrap|loose|files|deep>
mkpkg() {
    local out="$1" ver="$2" layout="$3" d
    d=$(mktemp -d "$WORK/pkg/XXXXXX")
    case "$layout" in
        wrap)
            mkdir -p "$d/selftest-app/bin"
            cp /usr/bin/sleep "$d/selftest-app/bin/dselftest"
            echo "$ver" > "$d/selftest-app/VERSION"
            printf 'PNG' > "$d/selftest-app/icon.png"
            tar -czf "$out" -C "$d" selftest-app ;;
        loose)
            mkdir -p "$d/bin" "$d/lib"
            cp /usr/bin/sleep "$d/bin/dselftest"
            echo "$ver" > "$d/VERSION"; echo x > "$d/lib/x.txt"; printf 'PNG' > "$d/icon.png"
            tar -czf "$out" -C "$d" bin lib VERSION icon.png ;;
        files)
            cp /usr/bin/sleep "$d/dselftest"
            echo "$ver" > "$d/VERSION"
            tar -czf "$out" -C "$d" dselftest VERSION ;;
        deep)
            mkdir -p "$d/selftest-app/opt/bin"
            cp /usr/bin/sleep "$d/selftest-app/opt/bin/dselftest"
            echo "$ver" > "$d/selftest-app/VERSION"
            tar -czf "$out" -C "$d" selftest-app ;;
    esac
}

mkpkg "$WORK/v1.tar.gz" v1 wrap
mkpkg "$WORK/v2.tar.gz" v2 wrap
mkpkg "$WORK/dselftest-v2.tar.gz" v2 wrap
mkpkg "$WORK/loose.tar.gz" loose loose
mkpkg "$WORK/files.tar.gz" files files
mkpkg "$WORK/deep.tar.gz" deep deep

cat > "$WORK/m.json" <<'EOF'
{"app_id":"com.dopt.selftest","name":"Dopt Selftest","binary_path":"bin/dselftest","icon_path":"icon.png","symlink_as":"dselftest","cli_only":"false"}
EOF
manifest() { jq "$1" "$WORK/m.json" > "$WORK/$2"; }
manifest '.cli_only=true' m-cli.json
manifest '.symlink_as="git"' m-git.json
manifest '.symlink_as="dselftest-taken"' m-taken.json
manifest '.binary_path="bin/missing"' m-bad.json
manifest 'del(.binary_path) | .binary_pattern="dselftest"' m-pattern.json
manifest '.name="Evil\nExec=/bin/rm -rf ~" | .comment="Line1\nLine2" | .exec_flags="%U --mode=gui"' m-evil.json

ZERO_SHA=$(printf '0%.0s' {1..64})

echo "dopt test suite ($("$DOPT" --version))"
echo "Test root: $DOPT_TEST_ROOT"

# ---------- install and update ----------
section "Install and update"
run 'y\nn\n' -m "$WORK/m.json" -f "$WORK/v1.tar.gz"
check "fresh install succeeds" ok
check "installed version is v1" version_is v1
check "registry entry written" test -f "$REG"
check "registry identity matches folder" test "$(sed -n 's/^folder_id=//p' "$REG")" = "$(stat -c '%i:%W' "$INST")"
check "command link points into install" link_to dselftest "$INST/bin/dselftest"
check "desktop file has no 'null'" bash -c "! grep -q null '$DESK'"
check "app folder left as shipped (no marker inside)" test ! -e "$INST/.dopt"

run 'n\n' -m "$WORK/m.json" -f "$WORK/v2.tar.gz"
check "update succeeds" ok
check "updated to v2" version_is v2
check "registered update doesn't ask about ownership" out_lacks "isn't registered"
check "no staging leftovers" test -z "$(find "$OPT" -maxdepth 1 -name '*.dopt-*')"

# ---------- ownership ----------
section "Ownership"
mv "$REG" "$WORK/reg.bak"
run 'n\n' -m "$WORK/m.json" -f "$WORK/v1.tar.gz"
check "unregistered folder prompts" out_has "isn't registered"
check "answering no leaves it untouched" version_is v2
run '' -m "$WORK/m.json" -f "$WORK/v1.tar.gz" -i
check "-i refuses to replace an unregistered folder" failed_with "Refusing to replace"
run 'y\nn\n' -m "$WORK/m.json" -f "$WORK/v1.tar.gz"
check "answering yes installs" version_is v1
check "and registers it" test -f "$REG"

mv "$INST" "$WORK/moved" && cp -a "$WORK/moved" "$INST"
run 'n\n' -m "$WORK/m.json" -f "$WORK/v2.tar.gz"
check "recreated folder is detected" out_has "replaced or recreated"
check "and left untouched" version_is v1
run 'y\nn\n' -m "$WORK/m.json" -f "$WORK/v2.tar.gz"

# ---------- recovery ----------
section "Recovery"
mv "$INST" "$OPT/.$APP.dopt-old"
run '' -m "$WORK/m-cli.json" -u "http://127.0.0.1:9/none.tar.gz" -s dselftest -i
check "interrupted swap is rolled back" bash -c "grep -qF 'restored' '$WORK/out' && [[ -d '$INST' ]]"

# Background processes must not hold the script's stdout open (it may be piped)
"$BIN/dselftest" 120 >/dev/null 2>&1 & APP_PID=$!; BG_PIDS+=("$APP_PID")
bash -c 'sleep 120; :' dselftest-decoy >/dev/null 2>&1 & DECOY_PID=$!; BG_PIDS+=("$DECOY_PID")
sleep 0.3
run '' -m "$WORK/m-cli.json" -f "$WORK/dselftest-v2.tar.gz" -s dselftest -i
check "update with running app succeeds (dopt didn't kill itself)" ok
check "running app was stopped" not_alive "$APP_PID"
check "unrelated process with the name in its args survives" is_alive "$DECOY_PID"
pkill -P "$DECOY_PID" 2>/dev/null; kill "$DECOY_PID" 2>/dev/null

# ---------- command-name clashes ----------
section "Command-name clashes"
if command -v git >/dev/null 2>&1; then
    run '' -m "$WORK/m-git.json" -f "$WORK/v1.tar.gz" -i
    check "clash with 'git' aborts under -i" failed_with "Deployment aborted"
    run '1\ndselftest-new\nn\n' -m "$WORK/m-git.json" -f "$WORK/v1.tar.gz"
    check "picking a new name installs under it" link_to dselftest-new "$INST/bin/dselftest"
    check "old link removed after rename" test ! -e "$BIN/dselftest"
else
    skip "git clash tests (git not installed)"
fi

echo '#!/bin/sh' > "$BIN/dselftest-taken"
run '1\nbad/name\n\ndselftest-fixed\nn\n' -m "$WORK/m-taken.json" -f "$WORK/v1.tar.gz"
check "taken link file is not overwritten" bash -c "[[ ! -L '$BIN/dselftest-taken' ]] && grep -qx '#!/bin/sh' '$BIN/dselftest-taken'"
check "invalid name is rejected" out_has "Invalid name"
check "empty name is rejected" out_has "Name cannot be empty"
check "valid new name is used" link_to dselftest-fixed "$INST/bin/dselftest"

run 'n\n' -m "$WORK/m.json" -f "$WORK/v1.tar.gz" -s dselftest-s
check "-s overrides the manifest's symlink_as" link_to dselftest-s "$INST/bin/dselftest"
run 'n\n' -m "$WORK/m.json" -f "$WORK/v1.tar.gz"
check "switching back removes the -s link" test ! -e "$BIN/dselftest-s"

# ---------- archives and binaries ----------
section "Archives and binaries"
run 'n\n' -m "$WORK/m.json" -f "$WORK/loose.tar.gz"
check "loose archive installs every top-level entry" bash -c "[[ -f '$INST/lib/x.txt' && -f '$INST/icon.png' ]]"
check "loose archive version" version_is loose

run 'n\n' -m "$WORK/m-pattern.json" -f "$WORK/files.tar.gz"
check "files-only archive installs" version_is files
check "binary_pattern finds top-level binary" link_to dselftest "$INST/dselftest"

run 'n\n' -m "$WORK/m-pattern.json" -f "$WORK/deep.tar.gz"
check "binary_pattern finds a binary 3 levels deep" link_to dselftest "$INST/opt/bin/dselftest"

run '\n\n\nnothere\n\n\n1\nn\n' -a "$APP" -f "$WORK/deep.tar.gz"
check "wizard offers the executable picker" out_has "Executables found in the package"
check "picked binary is linked" link_to dselftest "$INST/opt/bin/dselftest"

run '\n\n\nnothere\n\n\n\n' -a "$APP" -f "$WORK/v1.tar.gz"
check "Enter at the picker aborts" failed
check "and leaves the install untouched" version_is deep

# ---------- downloads ----------
section "Downloads"
if command -v python3 >/dev/null 2>&1; then
    PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
    python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/srv" >/dev/null 2>&1 &
    SERVER_PID=$!
    URL="http://127.0.0.1:$PORT"
    for _ in {1..50}; do curl -s -o /dev/null "$URL/" && break; sleep 0.1; done

    cp "$WORK/v1.tar.gz" "$WORK/srv/app.tar.gz"
    head -c 2000 /dev/urandom > "$WORK/srv/corrupt.tar.gz"

    run 'n\n' -m "$WORK/m.json" -u "$URL/app.tar.gz?token=abc#frag"
    check "download installs" version_is v1
    check "downloads add a Downloading step" out_has "[2/5] Downloading..."
    check "piped download shows no transfer table" out_lacks "% Total"
    check "query string stripped from saved name" test -f "$CWD/app.tar.gz"

    run 'n\n' -m "$WORK/m.json" -u "$URL/app.tar.gz"
    check "identical download reuses the saved copy" test ! -e "$CWD/app-1.tar.gz"

    cp "$WORK/v2.tar.gz" "$WORK/srv/app.tar.gz"
    run 'n\n' -m "$WORK/m.json" -u "$URL/app.tar.gz"
    check "different file with the same name is saved as -1" test -f "$CWD/app-1.tar.gz"
    check "original saved copy is untouched" cmp -s "$CWD/app.tar.gz" "$WORK/v1.tar.gz"

    before=$(file_count "$CWD")
    run '' -m "$WORK/m.json" -u "$URL/missing.tar.gz"
    check "404 fails" failed
    check "404 keeps nothing" test "$(file_count "$CWD")" -eq "$before"

    run '' -m "$WORK/m.json" -u "$URL/corrupt.tar.gz"
    check "corrupt archive fails" failed
    check "corrupt archive is not kept" test "$(file_count "$CWD")" -eq "$before"

    run 'n\n' -m "$WORK/m.json" -u "$URL/app.tar.gz" --sha256 "$(sha256sum "$WORK/v2.tar.gz" | cut -d' ' -f1)"
    check "--sha256 match installs" out_has "SHA-256 verified"
    run '' -m "$WORK/m.json" -u "$URL/app.tar.gz" --sha256 "$ZERO_SHA"
    check "--sha256 mismatch fails" failed_with "SHA-256 mismatch"
    check "mismatched download is not kept" test "$(file_count "$CWD")" -eq "$before"
else
    skip "download tests (python3 not installed)"
fi

# ---------- -c cleanup ----------
section "Cleanup (-c)"
cp "$WORK/v1.tar.gz" "$WORK/c1.tar.gz"
run 'y\nn\n' -m "$WORK/m.json" -f "$WORK/c1.tar.gz" -c
check "-c deletes the local archive after yes" test ! -e "$WORK/c1.tar.gz"
cp "$WORK/v1.tar.gz" "$WORK/c2.tar.gz"
run 'n\nn\n' -m "$WORK/m.json" -f "$WORK/c2.tar.gz" -c
check "-c keeps the local archive after no" test -f "$WORK/c2.tar.gz"
cp "$WORK/v1.tar.gz" "$WORK/c3.tar.gz"
run '' -m "$WORK/m-cli.json" -f "$WORK/c3.tar.gz" -s dselftest -c -i
check "-c with -i deletes without asking" test ! -e "$WORK/c3.tar.gz"
cp "$WORK/v1.tar.gz" "$WORK/c4.tar.gz"
run '' -m "$WORK/m-bad.json" -f "$WORK/c4.tar.gz" -c
check "-c keeps the archive when the install fails" test -f "$WORK/c4.tar.gz"
cp "$WORK/v1.tar.gz" "$WORK/c5.tar.gz"
run '' -m "$WORK/m.json" -f "$WORK/c5.tar.gz" --sha256 "$ZERO_SHA" -c
check "--sha256 mismatch on a local file keeps it" bash -c "[[ $RC -ne 0 && -f '$WORK/c5.tar.gz' ]]"

# ---------- desktop file ----------
section "Desktop file"
run 'n\n' -m "$WORK/m-evil.json" -f "$WORK/v1.tar.gz"
check "injected newline doesn't add a line" test "$(grep -c '^Exec=' "$DESK")" -eq 1
check "exactly one Name= line" test "$(grep -c '^Name=' "$DESK")" -eq 1
check "Exec path is quoted, field codes kept" grep -qF "Exec=\"$BIN/dselftest\" %U --mode=gui" "$DESK"
if command -v desktop-file-validate >/dev/null 2>&1; then
    check "desktop-file-validate passes" desktop-file-validate "$DESK"
else
    skip "desktop-file-validate (not installed)"
fi

# ---------- source selection ----------
section "Source selection"
run '' -m "$WORK/m.json" -p "$WORK"
check "-p reports it was removed" failed_with "-p was removed"
run '' -m "$WORK/m.json" -i
check "no source with -i stops" failed_with "No archive given"

mkdir -p "$DL"
cp "$WORK/v1.tar.gz" "$DL/older.tar.gz"; touch -d '3 days ago' "$DL/older.tar.gz"
cp "$WORK/v2.tar.gz" "$DL/newer.tar.gz"
run '1\nn\n' -m "$WORK/m.json"
check "recent downloads are listed" out_has "Recent downloads"
check "newest download is option 1" out_has "1) newer.tar.gz"
check "picking it installs" version_is v2

run "p\n'$WORK/v1.tar.gz'\nn\n" -m "$WORK/m.json"
check "typed (quoted) path installs" version_is v1
run 'a\n' -m "$WORK/m.json"
check "abort stops" failed

rm -rf -- "$DL"
run 'a\n' -m "$WORK/m.json"
check "missing downloads folder shows no list" out_lacks "Recent downloads"

# ---------- system-wide install present ----------
section "Existing system-wide install"
mkdir -p "$DOPT_TEST_ROOT/global-opt/$APP"
run '3\n' -m "$WORK/m.json" -f "$WORK/v1.tar.gz"
check "existing global install is detected" out_has "Found existing system-wide installation"
mkdir -p "$WORK/fakebin"
printf '#!/bin/sh\necho "FAKE SUDO: $*"\n' > "$WORK/fakebin/sudo"; chmod +x "$WORK/fakebin/sudo"
printf '1\n' | (cd "$CWD" && PATH="$WORK/fakebin:$PATH" "$DOPT" -m "$WORK/m.json" -f "$WORK/v1.tar.gz" -c) > "$WORK/out" 2>&1
check "elevating keeps all original options" out_has "-g -m $WORK/m.json -f $WORK/v1.tar.gz -c"
run '2\ny\ny\nn\n' -m "$WORK/m.json" -f "$WORK/v1.tar.gz" -s dselftest-local
check "isolated local install gets the (Local) name" grep -qx 'Name=Dopt Selftest (Local)' "$APPS/$APP-local.desktop"
rm -rf -- "$DOPT_TEST_ROOT/global-opt"

# ---------- output ----------
section "Output"
run 'n\n' -m "$WORK/m.json" -f "$WORK/v1.tar.gz"
check "piped output has no color codes" bash -c "! grep -q $'\e' '$WORK/out'"
check "steps are numbered" out_has "[1/4] Checking Dopt Selftest..."
check "last step is the menu shortcut" out_has "[4/4] Creating menu shortcut..."
check "summary says updated" out_has "[+] Dopt Selftest updated"
check "summary shows the location" out_has "Location   $INST"
check "summary shows the command" out_has "Command    dselftest"
run '' -m "$WORK/m-cli.json" -f "$WORK/v1.tar.gz" -s dselftest -i
check "CLI-only install has 3 steps" out_has "[3/3] Installing..."
check "CLI-only summary has no shortcut" out_has "Shortcut   none (CLI-only)"

if command -v python3 >/dev/null 2>&1; then
    PTY='import pty, sys; sys.exit(pty.spawn(sys.argv[1:]) >> 8)'
    (cd "$CWD" && python3 -c "$PTY" "$DOPT" -m "$WORK/m-cli.json" -f "$WORK/v1.tar.gz" -s dselftest -i) < /dev/null > "$WORK/out" 2>&1
    check "terminal output is colored" grep -q $'\e\[' "$WORK/out"
    (cd "$CWD" && NO_COLOR=1 python3 -c "$PTY" "$DOPT" -m "$WORK/m-cli.json" -f "$WORK/v1.tar.gz" -s dselftest -i) < /dev/null > "$WORK/out" 2>&1
    check "NO_COLOR disables color on a terminal" bash -c "! grep -q $'\e' '$WORK/out'"
else
    skip "terminal color tests (python3 not installed)"
fi

# ---------- static checks ----------
section "Static checks"
check "dopt.sh syntax" bash -n "$DOPT"
if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck (warnings and above)" shellcheck -S warning "$DOPT" "$0"
else
    skip "shellcheck (not installed)"
fi
if [[ "$REAL_HOME_APP_EXISTED" == false ]]; then
    check "nothing installed into the real ~/.local/opt" test ! -e "$REAL_HOME_APP"
fi

echo
echo "Result: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
