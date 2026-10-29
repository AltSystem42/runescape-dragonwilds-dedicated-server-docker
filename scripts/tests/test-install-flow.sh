#!/bin/bash
# Regression tests for the first-install flow in scripts/entrypoint-wrapper.sh
#
# Extracts the real install_or_verify_server() function and drives it with a
# fake SteamCMD. Guards against the issue #1 class of failure: SteamCMD exits 0
# (or fails) without installing anything, while the wrapper still reports
# success.
#
# Run from anywhere: bash scripts/tests/test-install-flow.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

# shellcheck source=../update-helper.sh
source "$REPO/scripts/update-helper.sh"

SERVERDIR="$TEST_TMP/Steam"
APPID=4019830
MANIFEST="$SERVERDIR/steamapps/appmanifest_$APPID.acf"
BINARY="$SERVERDIR/RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping"

mkdir -p "$SERVERDIR/steamapps"

LOG="$TEST_TMP/log"
DISCORD="$TEST_TMP/discord"
ARGS="$TEST_TMP/args"

log() { echo "$1" >> "$LOG"; }
send_discord() { echo "$1" >> "$DISCORD"; }
sleep() { :; }   # keep the retry loop instant

# Pull the real function out of the entrypoint.
eval "$(awk '/^install_or_verify_server\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$REPO/scripts/entrypoint-wrapper.sh")"

# Fake SteamCMD. It can exit successfully with or without creating the files
# the real install is supposed to produce.
cat > "$TEST_TMP/steamcmd.sh" <<'EOS'
#!/bin/bash
echo "$*" >> "$FAKE_ARGS"
if [[ "$*" == *app_update* ]]; then
    if [ "${FAKE_WRITE_MANIFEST:-false}" = "true" ]; then
        printf '"AppState"\n{\n\t"appid"\t\t"4019830"\n\t"buildid"\t\t"%s"\n}\n' \
            "${FAKE_BUILD:-26161880}" > "$FAKE_MANIFEST"
    fi
    if [ "${FAKE_WRITE_BINARY:-false}" = "true" ]; then
        mkdir -p "$(dirname "$FAKE_BINARY")"
        : > "$FAKE_BINARY"
    fi
    exit "${FAKE_UPDATE_EXIT:-0}"
fi
exit 0
EOS
chmod +x "$TEST_TMP/steamcmd.sh"
export STEAMCMD="$TEST_TMP/steamcmd.sh"
export FAKE_ARGS="$ARGS" FAKE_MANIFEST="$MANIFEST" FAKE_BINARY="$BINARY"

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }

assert_eq() { # description expected actual
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1 (expected [$2], got [$3])"
    fi
}

assert_log_has() { # description file needle
    if grep -qF -- "$3" "$2" 2>/dev/null; then
        pass "$1"
    else
        fail "$1 (missing [$3] in $(basename "$2"))"
    fi
}

assert_log_lacks() { # description file needle
    if grep -qF -- "$3" "$2" 2>/dev/null; then
        fail "$1 (unexpected [$3] in $(basename "$2"))"
    else
        pass "$1"
    fi
}

reset_case() {
    : > "$LOG"
    : > "$DISCORD"
    : > "$ARGS"
    rm -rf "$SERVERDIR/steamapps" "$SERVERDIR/RSDragonwilds"
    mkdir -p "$SERVERDIR/steamapps"
}

# ---------------------------------------------------------------------------
# 1. Successful install
# ---------------------------------------------------------------------------
reset_case
export FAKE_WRITE_MANIFEST=true FAKE_WRITE_BINARY=true FAKE_BUILD=26161880 FAKE_UPDATE_EXIT=0

install_or_verify_server
status=$?

assert_eq "install: successful install reports success" "0" "$status"
assert_eq "install: only one SteamCMD attempt needed" "1" \
    "$(grep -cF -- '+app_update' "$ARGS")"
assert_log_has "install: logs the installed build" "$LOG" "complete (build 26161880)"
assert_log_has "install: sends the success notification" "$DISCORD" "✅"
assert_log_lacks "install: no failure notification" "$DISCORD" "❌"
assert_eq "install: uses +app_info_update 1" "1" \
    "$(grep -cF -- '+app_info_update 1' "$ARGS")"

# ---------------------------------------------------------------------------
# 2. SteamCMD exits 0 but installs nothing (stale cache / partial install)
# ---------------------------------------------------------------------------
reset_case
export FAKE_WRITE_MANIFEST=false FAKE_WRITE_BINARY=false FAKE_UPDATE_EXIT=0

install_or_verify_server
status=$?

assert_eq "silent failure: reports failure" "1" "$status"
assert_eq "silent failure: retries all 5 attempts" "5" \
    "$(grep -cF -- '+app_update' "$ARGS")"
assert_log_has "silent failure: detects incomplete install" "$LOG" \
    "reported success but the install is incomplete"
assert_log_has "silent failure: explains what is missing" "$LOG" \
    "server binary is still missing"
assert_log_has "silent failure: sends the failure notification" "$DISCORD" "❌"
assert_log_lacks "silent failure: does not claim success" "$DISCORD" "✅"

# ---------------------------------------------------------------------------
# 3. SteamCMD itself fails
# ---------------------------------------------------------------------------
reset_case
export FAKE_WRITE_MANIFEST=false FAKE_WRITE_BINARY=false FAKE_UPDATE_EXIT=1

install_or_verify_server
status=$?

assert_eq "command failure: reports failure" "1" "$status"
assert_eq "command failure: retries all 5 attempts" "5" \
    "$(grep -cF -- '+app_update' "$ARGS")"
assert_log_has "command failure: logs the SteamCMD failure" "$LOG" \
    "SteamCMD failed, retrying"
assert_log_has "command failure: sends the failure notification" "$DISCORD" "❌"

# ---------------------------------------------------------------------------
# 4. Manifest written but binary missing
# ---------------------------------------------------------------------------
reset_case
export FAKE_WRITE_MANIFEST=true FAKE_WRITE_BINARY=false FAKE_BUILD=26161880 FAKE_UPDATE_EXIT=0

install_or_verify_server
status=$?

assert_eq "partial install: reports failure" "1" "$status"
assert_log_has "partial install: identifies the missing binary" "$LOG" \
    "server binary is still missing"

# ---------------------------------------------------------------------------
# 5. Binary written but manifest has no buildid
# ---------------------------------------------------------------------------
reset_case
export FAKE_WRITE_MANIFEST=false FAKE_WRITE_BINARY=true FAKE_UPDATE_EXIT=0

install_or_verify_server
status=$?

assert_eq "incomplete manifest: reports failure" "1" "$status"
assert_log_has "incomplete manifest: identifies the missing buildid" "$LOG" \
    "server manifest has no buildid"

# ---------------------------------------------------------------------------
if [ "$failures" -eq 0 ]; then
    printf '\nAll install-flow tests passed.\n'
    exit 0
fi

printf '\n%d install-flow test(s) failed.\n' "$failures"
exit 1
