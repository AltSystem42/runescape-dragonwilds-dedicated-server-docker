#!/bin/bash
# Player state helpers for the Dragonwilds entrypoint.
#
# Players are keyed by their stable account id instead of a display name.
# The server logs the Steam/platform persona name when a player joins but the
# in-game character name when they leave, and the two can differ. Matching on
# names leaves "ghost" players behind, so the online count never returns to
# zero and the idle-gated update/backup loops never run.
#
# Callers must set PLAYERS_FILE and PLAYER_COUNT_FILE before sourcing this file.
# The state file stores one "account_id<TAB>display_name" line per player.

# Read the online player count, treating a missing, empty or non-numeric file
# as 0 (an empty read used to break `[ "$count" -eq 0 ]` with set -e).
read_count() {
    local file="${1:-$PLAYER_COUNT_FILE}" value=""
    [ -f "$file" ] && value=$(cat "$file" 2>/dev/null)
    case "$value" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$value" ;;
    esac
}

# Write the count atomically so readers never observe a truncated file.
write_count() {
    local value="${1:-0}" tmp="${PLAYER_COUNT_FILE}.tmp"
    printf '%s\n' "$value" > "$tmp" && mv "$tmp" "$PLAYER_COUNT_FILE"
}

sync_count() {
    write_count "$(players_count)"
}

players_reset() {
    : > "$PLAYERS_FILE"
    write_count 0
}

players_count() {
    if [ ! -f "$PLAYERS_FILE" ]; then
        echo 0
        return 0
    fi
    wc -l < "$PLAYERS_FILE" | tr -d ' '
}

players_has_id() {
    local id="$1"
    [ -f "$PLAYERS_FILE" ] || return 1
    grep -qF -- "$id"$'\t' "$PLAYERS_FILE"
}

players_name_for() {
    local id="$1"
    [ -f "$PLAYERS_FILE" ] || return 0
    awk -F'\t' -v id="$id" '$1 == id { print $2; exit }' "$PLAYERS_FILE"
}

# Add a player. Emits "join<TAB>id<TAB>name" only when the player was not
# already tracked, so repeated log lines never produce duplicate notifications.
players_add() {
    local id="$1" name="$2"
    [ -n "$id" ] || return 0
    [ -n "$name" ] || name="$id"
    if players_has_id "$id"; then
        return 0
    fi
    printf '%s\t%s\n' "$id" "$name" >> "$PLAYERS_FILE"
    sync_count
    printf 'join\t%s\t%s\n' "$id" "$name"
}

# Remove a player by account id. Fixed-string matching avoids regex injection
# from names containing characters like '.', '*' or '['.
players_remove() {
    local id="$1" name tmp
    [ -n "$id" ] || return 0
    players_has_id "$id" || return 0

    name=$(players_name_for "$id")
    tmp="${PLAYERS_FILE}.tmp"
    grep -vF -- "$id"$'\t' "$PLAYERS_FILE" > "$tmp" || true
    mv "$tmp" "$PLAYERS_FILE"
    sync_count
    printf 'leave\t%s\t%s\n' "$id" "${name:-$id}"
}

# Parse a single log line and update player state.
#   LogDomMatcherSession: Player ADDED to session [<id>]-[<name>]
#   LogDomMatcherSession: Player Removed from session [<id>]-[<name>]
#   LogDominionPlayerController: ClientRequestDisconnect ... Account[XP:<id>] ... Character Name[<name>]
#   LogDominionPlayerControllerBase: PlayerChar entered world [Account[XP:<id>] Character Name[<name>] ...]
process_player_log_line() {
    local line="$1"
    # Keep patterns in variables: inline backslashes are not reliably
    # preserved by [[ =~ ]] across bash versions.
    local re_added='Player[[:space:]]+ADDED[[:space:]]+to[[:space:]]+session[[:space:]]+\[([^]]+)\]-\[([^]]*)\]'
    local re_removed='Player[[:space:]]+Removed[[:space:]]+from[[:space:]]+session[[:space:]]+\[([^]]+)\]'
    local re_account='Account\[XP:([^]]+)\].*Character[[:space:]]+Name\[([^]]*)\]'

    case "$line" in
        *"LogDomMatcherSession: Player ADDED to session ["*)
            if [[ "$line" =~ $re_added ]]; then
                players_add "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
            fi
            ;;
        *"LogDomMatcherSession: Player Removed from session ["*)
            if [[ "$line" =~ $re_removed ]]; then
                players_remove "${BASH_REMATCH[1]}"
            fi
            ;;
        *"LogDominionPlayerController: ClientRequestDisconnect"*)
            if [[ "$line" =~ $re_account ]]; then
                players_remove "${BASH_REMATCH[1]}"
            fi
            ;;
        *"LogDominionPlayerControllerBase: PlayerChar entered world [Account[XP:"*)
            if [[ "$line" =~ $re_account ]]; then
                players_add "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
            fi
            ;;
    esac
    return 0
}

# Process every line of a log chunk, emitting join/leave events on stdout.
# Lines without a trailing newline are still processed; re-processing a partial
# line later is harmless because add/remove are idempotent.
process_player_log_chunk() {
    local file="$1" line
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        process_player_log_line "$line"
    done < "$file"
}
