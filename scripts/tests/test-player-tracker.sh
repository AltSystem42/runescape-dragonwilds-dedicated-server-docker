#!/bin/bash
# Regression tests for scripts/player-tracker.sh
#
# Run from anywhere: bash scripts/tests/test-player-tracker.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACKER="$SCRIPT_DIR/../player-tracker.sh"

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export PLAYERS_FILE="$TEST_TMP/.online_players"
export PLAYER_COUNT_FILE="$TEST_TMP/.player_count"
CHUNK="$TEST_TMP/chunk"

# shellcheck source=../player-tracker.sh
source "$TRACKER"

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

assert_contains() { # description haystack needle
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1 (missing [$3] in [$2])" ;;
    esac
}

assert_empty() { # description value
    if [ -z "$2" ]; then
        pass "$1"
    else
        fail "$1 (expected empty, got [$2])"
    fi
}

# number of event lines in a captured stdout string
event_count() {
    if [ -z "$1" ]; then
        echo 0
    else
        printf '%s\n' "$1" | wc -l | tr -d ' '
    fi
}

# Feed a heredoc chunk through the parser and echo the emitted events.
run_chunk() {
    cat > "$CHUNK"
    process_player_log_chunk "$CHUNK"
}

# ---------------------------------------------------------------------------
# 1. Real log sample (issue #17, names happen to match)
# ---------------------------------------------------------------------------
players_reset

events=$(run_chunk <<'EOF'
[2026.10.10-12.27.18:475][861]LogDomMatcherSession: Player ADDED to session [0002415fe5ef46e0b7844f7f0e19920a]-[Baalmortum]
[2026.10.10-12.27.21:186][942]LogDominionPlayerControllerBase: PlayerChar entered world [Account[XP:0002415fe5ef46e0b7844f7f0e19920a] Character Name[Baalmortum] Guid[DCG:FDB6974E4049D9F7038B0EAB33FE1CF7] Type[0]]
EOF
)
assert_eq "real log: one player online" "1" "$(read_count)"
assert_eq "real log: one join event (world-enter fallback deduped)" "1" "$(event_count "$events")"
assert_contains "real log: join event carries the name" "$events" $'join\t0002415fe5ef46e0b7844f7f0e19920a\tBaalmortum'

events=$(run_chunk <<'EOF'
[2026.10.10-12.27.57:668][ 32]LogDominionPlayerController: RequestGameExit : Server saving World and Player state for Account[XP:0002415fe5ef46e0b7844f7f0e19920a] Character Name[Baalmortum] Guid[DCG:FDB6974E4049D9F7038B0EAB33FE1CF7] Type[0]
[2026.10.10-12.27.57:804][ 35]LogDominionPlayerController: ClientRequestDisconnect : DisconnectMe : PlayerStateSave result[true] - state saved for Account[XP:0002415fe5ef46e0b7844f7f0e19920a] Character Name[Baalmortum] Guid[DCG:FDB6974E4049D9F7038B0EAB33FE1CF7] Type[0]
[2026.10.10-12.27.57:937][ 39]LogDomMatcherSession: Player Removed from session [0002415fe5ef46e0b7844f7f0e19920a]-[Baalmortum]
EOF
)
assert_eq "real log: player count returns to zero" "0" "$(read_count)"
assert_eq "real log: exactly one leave event" "1" "$(event_count "$events")"

# ---------------------------------------------------------------------------
# 2. Regression: Steam name != character name (upstream issue #18)
# ---------------------------------------------------------------------------
players_reset

run_chunk >/dev/null <<'EOF'
[2026.10.10-12.27.18:475][861]LogDomMatcherSession: Player ADDED to session [aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa]-[SteamPersona]
EOF
assert_eq "name mismatch: player counted on join" "1" "$(read_count)"

events=$(run_chunk <<'EOF'
[2026.10.10-12.27.57:804][ 35]LogDominionPlayerController: ClientRequestDisconnect : DisconnectMe : PlayerStateSave result[true] - state saved for Account[XP:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa] Character Name[CharName] Guid[DCG:11111111111111111111111111111111] Type[0]
[2026.10.10-12.27.57:937][ 39]LogDomMatcherSession: Player Removed from session [aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa]-[SteamPersona]
EOF
)
assert_eq "name mismatch: player removed by account id" "0" "$(read_count)"
assert_eq "name mismatch: exactly one leave event" "1" "$(event_count "$events")"
assert_contains "name mismatch: leave event uses tracked name" "$events" "SteamPersona"

# ---------------------------------------------------------------------------
# 3. Abrupt disconnect: only the matcher-session removal is logged
# ---------------------------------------------------------------------------
players_reset

run_chunk >/dev/null <<'EOF'
[2026.10.10-12.27.18:475][861]LogDomMatcherSession: Player ADDED to session [bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb]-[Dropped]
EOF
events=$(run_chunk <<'EOF'
[2026.10.10-12.27.57:937][ 39]LogDomMatcherSession: Player Removed from session [bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb]-[Dropped]
EOF
)
assert_eq "abrupt disconnect: count back to zero" "0" "$(read_count)"
assert_eq "abrupt disconnect: leave event emitted" "1" "$(event_count "$events")"

# ---------------------------------------------------------------------------
# 4. Duplicate joins do not increment or notify twice
# ---------------------------------------------------------------------------
players_reset

events=$(run_chunk <<'EOF'
[2026.10.10-12.27.18:475][861]LogDomMatcherSession: Player ADDED to session [cccccccccccccccccccccccccccccccc]-[Dupe]
[2026.10.10-12.27.18:476][861]LogDomMatcherSession: Player ADDED to session [cccccccccccccccccccccccccccccccc]-[Dupe]
[2026.10.10-12.27.21:186][942]LogDominionPlayerControllerBase: PlayerChar entered world [Account[XP:cccccccccccccccccccccccccccccccc] Character Name[Dupe] Guid[DCG:22222222222222222222222222222222] Type[0]]
EOF
)
assert_eq "duplicate joins: one player online" "1" "$(read_count)"
assert_eq "duplicate joins: one join event" "1" "$(event_count "$events")"

# ---------------------------------------------------------------------------
# 5. Unknown removal is a no-op
# ---------------------------------------------------------------------------
players_reset

events=$(run_chunk <<'EOF'
[2026.10.10-12.27.57:937][ 39]LogDomMatcherSession: Player Removed from session [dddddddddddddddddddddddddddddddd]-[Nobody]
EOF
)
assert_eq "unknown removal: count stays zero" "0" "$(read_count)"
assert_empty "unknown removal: no event emitted" "$events"

# ---------------------------------------------------------------------------
# 6. Names with regex metacharacters are handled safely
# ---------------------------------------------------------------------------
players_reset

run_chunk >/dev/null <<'EOF'
[2026.10.10-12.27.18:475][861]LogDomMatcherSession: Player ADDED to session [eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee]-[A.*B]
[2026.10.10-12.27.18:476][861]LogDomMatcherSession: Player ADDED to session [ffffffffffffffffffffffffffffffff]-[x[y]]
EOF
run_chunk >/dev/null <<'EOF'
[2026.10.10-12.27.57:937][ 39]LogDomMatcherSession: Player Removed from session [eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee]-[A.*B]
EOF
assert_eq "regex names: only the removed player is gone" "1" "$(read_count)"
if grep -qF -- "ffffffffffffffffffffffffffffffff"$'\t' "$PLAYERS_FILE"; then
    pass "regex names: remaining player intact"
else
    fail "regex names: remaining player was corrupted"
fi
if compgen -G "${PLAYERS_FILE}.tmp" >/dev/null; then
    fail "regex names: temp file left behind"
else
    pass "regex names: no temp file left behind"
fi

# ---------------------------------------------------------------------------
# 7. Count reader tolerates missing/empty/garbage files
# ---------------------------------------------------------------------------
: > "$PLAYER_COUNT_FILE"
assert_eq "read_count: empty file" "0" "$(read_count)"
printf 'garbage\n' > "$PLAYER_COUNT_FILE"
assert_eq "read_count: non-numeric file" "0" "$(read_count)"
printf '3\n' > "$PLAYER_COUNT_FILE"
assert_eq "read_count: valid value" "3" "$(read_count)"
rm -f "$PLAYER_COUNT_FILE"
assert_eq "read_count: missing file" "0" "$(read_count)"

# ---------------------------------------------------------------------------
# 8. Interleaved players across one chunk
# ---------------------------------------------------------------------------
players_reset

events=$(run_chunk <<'EOF'
[2026.10.10-12.27.18:475][861]LogDomMatcherSession: Player ADDED to session [11111111111111111111111111111111]-[Alice]
[2026.10.10-12.27.18:476][861]LogDomMatcherSession: Player ADDED to session [22222222222222222222222222222222]-[Bob]
[2026.10.10-12.27.57:937][ 39]LogDomMatcherSession: Player Removed from session [11111111111111111111111111111111]-[Alice]
EOF
)
assert_eq "mixed chunk: one player remains" "1" "$(read_count)"
assert_eq "mixed chunk: two joins and one leave" "3" "$(event_count "$events")"

# ---------------------------------------------------------------------------
# 9. Partial final line is processed once (idempotent on re-read)
# ---------------------------------------------------------------------------
players_reset

printf '%s' '[2026.10.10-12.27.18:475][861]LogDomMatcherSession: Player ADDED to session [33333333333333333333333333333333]-[Partial]' > "$CHUNK"
events=$(process_player_log_chunk "$CHUNK")
assert_eq "partial line: player counted" "1" "$(read_count)"
assert_eq "partial line: join emitted" "1" "$(event_count "$events")"

events=$(process_player_log_chunk "$CHUNK")
assert_eq "partial line: re-read is idempotent" "1" "$(read_count)"
assert_empty "partial line: re-read emits nothing" "$events"

# ---------------------------------------------------------------------------
# 10. Reset clears both state files
# ---------------------------------------------------------------------------
players_reset
assert_eq "reset: count cleared" "0" "$(read_count)"
assert_eq "reset: player file empty" "0" "$(players_count)"

# ---------------------------------------------------------------------------
if [ "$failures" -eq 0 ]; then
    printf '\nAll player-tracker tests passed.\n'
    exit 0
fi

printf '\n%d player-tracker test(s) failed.\n' "$failures"
exit 1
