#!/bin/bash
# Regression tests for the update flow in scripts/entrypoint-wrapper.sh
#
# Extracts the real run_update() function and drives it with a fake SteamCMD so
# the issue #17 behaviour (SteamCMD exits 0 but leaves the old build installed)
# cannot silently come back.
#
# Run from anywhere: bash scripts/tests/test-update-flow.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

# shellcheck source=../update-helper.sh
source "$REPO/scripts/update-helper.sh"

SERVERDIR="$TEST_TMP/Steam"
APPID=4019830
CONFIGFILE="$SERVERDIR/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini"
BACKUPDIR="$SERVERDIR/backup"
LAST_APPLIED_BUILD_FILE="$SERVERDIR/.last_applied_build"
UPDATE_IN_PROGRESS_FILE="$SERVERDIR/.update_in_progress"
BACKUP_AFTER_UPDATE=false
MANIFEST="$SERVERDIR/steamapps/appmanifest_$APPID.acf"

mkdir -p "$SERVERDIR/steamapps" "$BACKUPDIR" "$(dirname "$CONFIGFILE")"
echo "config" > "$CONFIGFILE"

LOG="$TEST_TMP/log"
DISCORD="$TEST_TMP/discord"
STOPS="$TEST_TMP/stops"
ARGS="$TEST_TMP/args"

log() { echo "$1" >> "$LOG"; }
send_discord() { echo "$1" >> "$DISCORD"; }
wait_for_idle() { :; }
stop_server() { echo stop >> "$STOPS"; }
backup_saves() { :; }
cleanup_backups() { :; }
sleep() { :; }   # keep the 5-attempt retry loop instant

# Pull the real function out of the entrypoint.
eval "$(awk '/^run_update\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$REPO/scripts/entrypoint-wrapper.sh")"

write_manifest() {
    printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"buildid"\t\t"%s"\n}\n' "$APPID" "$1" > "$MANIFEST"
}

# Fake SteamCMD: always reports $FAKE_REMOTE_BUILD as the public build, and
# only rewrites the manifest when FAKE_APPLY=true (i.e. the update really
# landed). This mirrors the real-world "exit 0, no change" failure.
cat > "$TEST_TMP/steamcmd.sh" <<'EOS'
#!/bin/bash
echo "$*" >> "$FAKE_ARGS"
if [[ "$*" == *app_info_print* ]]; then
    cat <<EOF
"4019830"
{
	"depots"
	{
		"branches"
		{
			"public"
			{
				"buildid"		"$FAKE_REMOTE_BUILD"
			}
		}
	}
}
EOF
    exit 0
fi
if [[ "$*" == *app_update* ]]; then
    if [ "${FAKE_APPLY:-false}" = "true" ]; then
        printf '"AppState"\n{\n\t"appid"\t\t"4019830"\n\t"buildid"\t\t"%s"\n}\n' \
            "$FAKE_REMOTE_BUILD" > "$FAKE_MANIFEST"
    fi
    exit "${FAKE_UPDATE_EXIT:-0}"
fi
exit 0
EOS
chmod +x "$TEST_TMP/steamcmd.sh"
export STEAMCMD="$TEST_TMP/steamcmd.sh"
export FAKE_ARGS="$ARGS" FAKE_MANIFEST="$MANIFEST"

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
    : > "$STOPS"
    : > "$ARGS"
    rm -f "$LAST_APPLIED_BUILD_FILE" "$UPDATE_IN_PROGRESS_FILE"
}

# ---------------------------------------------------------------------------
# 1. Issue #17: SteamCMD exits 0 but the manifest still has the old build
# ---------------------------------------------------------------------------
reset_case
write_manifest 25805654
export FAKE_REMOTE_BUILD=25808123 FAKE_APPLY=false FAKE_UPDATE_EXIT=0

run_update
status=$?

assert_eq "stale update: run_update reports failure" "1" "$status"
if [ -f "$LAST_APPLIED_BUILD_FILE" ]; then
    fail "stale update: applied build must not be recorded"
else
    pass "stale update: applied build must not be recorded"
fi
assert_log_has "stale update: warns that the old build is still installed" \
    "$LOG" "still 25805654"
assert_log_has "stale update: points at stale cached app info" \
    "$LOG" "cached app info is probably stale"
assert_log_lacks "stale update: does not claim verification" \
    "$LOG" "Update verified"
assert_log_has "stale update: tells Discord the update failed" \
    "$DISCORD" "could not be applied"
assert_log_lacks "stale update: does not send the success message" \
    "$DISCORD" "✅"
if [ -f "$UPDATE_IN_PROGRESS_FILE" ]; then
    fail "stale update: maintenance flag released so the server restarts"
else
    pass "stale update: maintenance flag released so the server restarts"
fi
assert_eq "stale update: server restarted exactly once" "1" "$(grep -c . "$STOPS")"
assert_eq "stale update: both SteamCMD calls refresh app info" "2" \
    "$(grep -cF -- '+app_info_update 1' "$ARGS")"

# ---------------------------------------------------------------------------
# 2. SteamCMD actually installs the new build
# ---------------------------------------------------------------------------
reset_case
write_manifest 25805654
export FAKE_REMOTE_BUILD=25808123 FAKE_APPLY=true FAKE_UPDATE_EXIT=0

run_update
status=$?

assert_eq "successful update: run_update reports success" "0" "$status"
assert_eq "successful update: remote build recorded as applied" "25808123" \
    "$(cat "$LAST_APPLIED_BUILD_FILE" 2>/dev/null || echo "missing")"
assert_eq "successful update: manifest now has the remote build" "25808123" \
    "$(parse_manifest_buildid "$MANIFEST")"
assert_log_has "successful update: logs verification" "$LOG" "Update verified"
assert_log_has "successful update: sends the success message" "$DISCORD" "✅"
assert_log_lacks "successful update: no failure warning" "$DISCORD" "could not be applied"
if [ -f "$UPDATE_IN_PROGRESS_FILE" ]; then
    fail "successful update: maintenance flag released"
else
    pass "successful update: maintenance flag released"
fi

# ---------------------------------------------------------------------------
# 3. Already up to date: do not stop the server or run app_update
# ---------------------------------------------------------------------------
reset_case
write_manifest 25808123
export FAKE_REMOTE_BUILD=25808123 FAKE_APPLY=false FAKE_UPDATE_EXIT=0

run_update
status=$?

assert_eq "up to date: run_update reports success" "0" "$status"
assert_log_has "up to date: logs no update needed" "$LOG" "up to date"
assert_eq "up to date: server is not stopped" "0" "$(grep -c . "$STOPS" 2>/dev/null || true)"
assert_eq "up to date: app_update is not invoked" "0" \
    "$(grep -cF -- '+app_update' "$ARGS" 2>/dev/null || true)"
assert_log_lacks "up to date: no update notification" "$DISCORD" "🛠️"

# ---------------------------------------------------------------------------
# 4. SteamCMD itself fails: try 5 times, do not record success
# ---------------------------------------------------------------------------
reset_case
write_manifest 25805654
export FAKE_REMOTE_BUILD=25808123 FAKE_APPLY=false FAKE_UPDATE_EXIT=1

run_update
status=$?

assert_eq "failed update: run_update reports failure" "1" "$status"
assert_eq "failed update: SteamCMD retried 5 times" "5" \
    "$(grep -cF -- '+app_update' "$ARGS")"
assert_log_has "failed update: warns about the failure" "$LOG" "failed after 5 attempts"
if [ -f "$LAST_APPLIED_BUILD_FILE" ]; then
    fail "failed update: applied build must not be recorded"
else
    pass "failed update: applied build must not be recorded"
fi

# ---------------------------------------------------------------------------
# 5. Legacy state: a stale .last_applied_build must not suppress the retry
# ---------------------------------------------------------------------------
reset_case
write_manifest 25805654
echo 25808123 > "$LAST_APPLIED_BUILD_FILE"   # written by the old buggy version
export FAKE_REMOTE_BUILD=25808123 FAKE_APPLY=true FAKE_UPDATE_EXIT=0

run_update
status=$?

assert_eq "legacy state: update still attempted and verified" "0" "$status"
assert_eq "legacy state: app_update was invoked" "1" \
    "$(grep -cF -- '+app_update' "$ARGS")"
assert_eq "legacy state: manifest now has the remote build" "25808123" \
    "$(parse_manifest_buildid "$MANIFEST")"

# ---------------------------------------------------------------------------
if [ "$failures" -eq 0 ]; then
    printf '\nAll update-flow tests passed.\n'
    exit 0
fi

printf '\n%d update-flow test(s) failed.\n' "$failures"
exit 1
