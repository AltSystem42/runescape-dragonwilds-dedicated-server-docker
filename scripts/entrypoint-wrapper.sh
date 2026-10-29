#!/bin/bash
set -e

# --- DROP PRIVILEGES ---
# If running as root, match the ubuntu user's UID/GID to the volume owner
# so the server process can read/write the mounted directory without the
# host user needing to chmod or chown anything.
if [ "$(id -u)" = "0" ]; then
    VOLUME_UID=$(stat -c '%u' "${SERVERDIR:-/home/ubuntu/Steam}" 2>/dev/null || echo "1000")
    VOLUME_GID=$(stat -c '%g' "${SERVERDIR:-/home/ubuntu/Steam}" 2>/dev/null || echo "1000")
    # If the volume is owned by root (e.g. not yet mounted / empty), fall back to 1000
    if [ "$VOLUME_UID" = "0" ]; then
        VOLUME_UID=1000
        VOLUME_GID=1000
    fi
    groupmod -g "$VOLUME_GID" ubuntu 2>/dev/null || true
    usermod  -u "$VOLUME_UID" ubuntu 2>/dev/null || true
    # Only chown internal dirs — do NOT recurse into the bind-mounted volume
    chown ubuntu:ubuntu /home/ubuntu
    chown -R ubuntu:ubuntu /home/ubuntu/steamcmd
    chown -R ubuntu:ubuntu /home/ubuntu/Steam
    exec gosu ubuntu "$0" "$@"
fi

# --- ENVIRONMENT VARIABLES ---
APPID=4019830
STEAMCMD="${STEAMCMD:-/home/ubuntu/steamcmd/steamcmd.sh}"
SERVERDIR="${SERVERDIR:-/home/ubuntu/Steam}"
CONFIGFILE="$SERVERDIR/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini"
BACKUPDIR="$SERVERDIR/backup"
LOGFILE="$SERVERDIR/logs/entrypoint.log"
LAST_ACTIVITY_FILE="$SERVERDIR/.last_activity"
PLAYER_COUNT_FILE="$SERVERDIR/.player_count"
PLAYERS_FILE="$SERVERDIR/.online_players"
PLAYER_CHUNK_FILE="/tmp/dragonwilds-player-chunk.$$"
SERVER_PID_FILE="$SERVERDIR/.server_pid"
LAST_BACKUP_DATE_FILE="$SERVERDIR/.last_backup_date"
LAST_APPLIED_BUILD_FILE="$SERVERDIR/.last_applied_build"
UPDATE_IN_PROGRESS_FILE="$SERVERDIR/.update_in_progress"
BACKUP_IN_PROGRESS_FILE="$SERVERDIR/.backup_in_progress"
SERVER_PORT="${SERVER_PORT:-7777}"
ENABLE_AUTO_UPDATE="${ENABLE_AUTO_UPDATE:-true}"
UPDATE_TIME="${UPDATE_TIME:-3600}"              # How often (seconds) to check for updates (e.g. 3600 = every hour)
UPDATE_BACKOFF_MAX="${UPDATE_BACKOFF_MAX:-86400}" # Max delay between retries after a failed update (default 24h)
ENABLE_DISCORD_NOTIF="${ENABLE_DISCORD_NOTIF:-false}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
IDLE_WAIT="${IDLE_WAIT:-360}"
SERVER_STOP_TIMEOUT="${SERVER_STOP_TIMEOUT:-120}"   # Max seconds to wait for the server to stop before SIGKILL
LOG_TO_STDOUT="${LOG_TO_STDOUT:-true}"              # Also echo script log lines to the container stdout (docker logs)
MAX_LOG_SIZE="${MAX_LOG_SIZE:-5242880}"             # Rotate the script log once it reaches this many bytes (default 5 MB)
LOG_RETENTION="${LOG_RETENTION:-5}"                 # Number of rotated script log generations to keep
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
PLAYER_CHECK_INTERVAL=5
BACKUP_AFTER_UPDATE="${BACKUP_AFTER_UPDATE:-true}"
BACKUP_DAILY="${BACKUP_DAILY:-true}"
BACKUP_TIME="${BACKUP_TIME:-3:00 AM}"           # Time-of-day to run daily backup (12-hour format)
POLL_INTERVAL="${POLL_INTERVAL:-60}"            # How often (seconds) the backup loop checks the schedule

# --- DEDICATEDSERVER.INI CONFIGURATION ---
ADMIN_PASSWORD="${ADMIN_PASSWORD}"              # Provided
OWNER_ID="${OWNER_ID}"                          # Required
SERVER_GUID="${SERVER_GUID}"                    # Provided
SERVER_NAME="${SERVER_NAME}"                    # Provided
WORLD_PASSWORD="${WORLD_PASSWORD}"              # Optional
DEFAULT_WORLD_NAME="${DEFAULT_WORLD_NAME}"      # Provided

# Player tracking and update verification live in separate helpers so they
# can be unit-tested without running the container.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=player-tracker.sh
source "$SCRIPT_DIR/player-tracker.sh"
# shellcheck source=update-helper.sh
source "$SCRIPT_DIR/update-helper.sh"

HOME=/home/ubuntu
mkdir -p "$BACKUPDIR" "$SERVERDIR/steamapps" "$(dirname "$LOGFILE")"

# Migrate an old entrypoint.log that used to live in the game log directory,
# so existing history isn't lost when the script log moves to logs/.
OLD_LOGFILE="$SERVERDIR/RSDragonwilds/Saved/Logs/entrypoint.log"
if [ -f "$OLD_LOGFILE" ] && [ ! -f "$LOGFILE" ]; then
    mv "$OLD_LOGFILE" "$LOGFILE"
fi

# Rotate the script log once it grows past MAX_LOG_SIZE instead of deleting
# it, so history survives container restarts (e.g. after every update).
# Total footprint is bounded by MAX_LOG_SIZE x LOG_RETENTION.
if [ "$LOG_RETENTION" -gt 1 ] && [ -s "$LOGFILE" ] && [ "$(stat -c %s "$LOGFILE")" -ge "$MAX_LOG_SIZE" ]; then
    for n in $(seq $((LOG_RETENTION - 1)) -1 1); do
        [ -f "$LOGFILE.$n" ] && mv "$LOGFILE.$n" "$LOGFILE.$((n + 1))"
    done
    mv "$LOGFILE" "$LOGFILE.1"
fi

log() {
    # Timestamp prefixed in the log file; plain on stdout so that docker logs
    # output keeps its current shape.
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"
    if [ "$LOG_TO_STDOUT" = "true" ]; then
        echo "$1"
    fi
}

# --- FUNCTION TO SEND DISCORD NOTIFICATION ---
send_discord() {
    if [ "$ENABLE_DISCORD_NOTIF" = "true" ] && [ -n "$DISCORD_WEBHOOK_URL" ]; then
        curl -s -X POST -H "Content-Type: application/json" \
            -d "{\"content\":\"$1\"}" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1
    fi
}

# --- INSTALL / VERIFY SERVER FILES VIA STEAMCMD ---
# SteamCMD can exit 0 without actually installing anything (stale app-info
# cache, disk/permission problems). Verify the manifest and binary after each
# attempt instead of reporting success based on the exit status alone.
# Returns 0 only when the install is complete, 1 otherwise.
install_or_verify_server() {
    local manifest="$SERVERDIR/steamapps/appmanifest_$APPID.acf"
    local binary="$SERVERDIR/RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping"
    local installed_build="" attempt

    log "=== Installing/verifying server files via SteamCMD ==="
    send_discord "📥 Installing Dragonwilds Dedicated Server — this may take a while..."

    for attempt in {1..5}; do
        log "SteamCMD attempt $attempt..."
        if "$STEAMCMD" \
            +force_install_dir "$SERVERDIR" \
            +login anonymous \
            +app_info_update 1 \
            +app_update $APPID validate \
            +quit; then
            installed_build=$(parse_manifest_buildid "$manifest" 2>/dev/null || true)
            if [ -n "$installed_build" ] && [ -f "$binary" ]; then
                log "=== SteamCMD install/verify complete (build $installed_build) ==="
                send_discord "✅ Dragonwilds Dedicated Server installed (build $installed_build)."
                return 0
            fi
            log "SteamCMD reported success but the install is incomplete — retrying in 5 seconds..."
        else
            log "SteamCMD failed, retrying in 5 seconds..."
        fi
        sleep 5
    done

    if [ ! -f "$binary" ]; then
        log "ERROR: server binary is still missing at $binary after 5 SteamCMD attempts"
    else
        log "ERROR: server manifest has no buildid at $manifest after 5 SteamCMD attempts"
    fi
    send_discord "❌ Dragonwilds Dedicated Server install failed — check the container logs."
    return 1
}

# -- DEDICATEDSERVER.INI ---
#
# Generate the ini file if needed, then provide it with (at least) the OwnerId
# This avoids an otherwise unnecessary restart during first-time setup that
# occurs in the standard flow where the server generates its own ini file but
# lacks the OwnerId.
#
# This will also update the ini file each time the container starts, making it
# a little easier to change server settings via environment

prepare_dedicated_server_ini() {
    set_key() {
        local key="$1"
        local new_value="$2"
        local escaped

        [ -n "$key" ] || { echo "Error: Key required."; return 1; }

        if grep -qE "^[[:space:]]*$key=" "$CONFIGFILE"; then
            # Key already present. An empty value means "keep what's there"
            # (a manual ini edit or a previous env override is preserved).
            if [ -n "$new_value" ]; then
                # Escape characters that are special in a sed replacement
                # (&, | and backslash) so arbitrary values survive intact.
                escaped=$(printf '%s' "$new_value" | sed -e 's/[\\&|]/\\&/g')
                sed -i.bak -E "s|^([[:space:]]*$key=).*|\1$escaped|" "$CONFIGFILE"
            fi
        elif [ -n "$new_value" ]; then
            # Key absent — only append when we have a value, so we never
            # write bare keys like "OwnerId=" with no value.
            echo "$key=$new_value" >> "$CONFIGFILE"
        fi
    }

    # Echo a generated default only when the key is missing from the ini
    # (i.e. a fresh install). When the key exists, echo nothing so set_key
    # preserves the existing value instead of clobbering it with a new
    # timestamp/random value on every container restart.
    default_echo() {
        if grep -qE "^[[:space:]]*$1=" "$CONFIGFILE"; then
            echo ""
        else
            echo "$2"
        fi
    }

    create_config_file() {
        echo "Config file '$CONFIGFILE' not found, creating."
        mkdir -p "$(dirname "$CONFIGFILE")" && touch "$CONFIGFILE"

        # Add metadata and section header
        echo ";METADATA=(Diff=true, UseCommands=true)" >> "$CONFIGFILE"
        echo "[/Script/Dominion.DedicatedServerSettings]" >> "$CONFIGFILE"
    }

    # Config.presence
    if [[ ! -f "$CONFIGFILE" ]]; then create_config_file; fi

    set_key "OwnerId"          "${OWNER_ID}"
    set_key "ServerGuid"       "${SERVER_GUID}"
    set_key "AdminPassword"    "${ADMIN_PASSWORD:-$(default_echo AdminPassword "$(openssl rand -hex 16 | tr 'a-f' 'A-F')")}"
    set_key "ServerName"       "${SERVER_NAME:-$(default_echo ServerName "Server-$(date +%s)")}"
    set_key "DefaultWorldName" "${DEFAULT_WORLD_NAME:-$(default_echo DefaultWorldName "World-$(date +%s)")}"
    set_key "WorldPassword"    "${WORLD_PASSWORD}"

    # private function cleanup
    unset -f set_key
    unset -f default_echo
    unset -f create_config_file
}

# --- START SERVER ---
start_server() {
    local binary="$SERVERDIR/RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping"
    if [ ! -f "$binary" ]; then
        log "ERROR: Server binary not found at $binary — cannot start"
        return 1
    fi
    log "=== Starting Dragonwilds Server on port ${SERVER_PORT} ==="
    cd "$SERVERDIR/RSDragonwilds/Binaries/Linux"
    ./RSDragonwildsServer-Linux-Shipping RSDragonwilds -log -Port="${SERVER_PORT}" &
    SERVER_PID=$!
    echo "$SERVER_PID" > "$SERVER_PID_FILE"
}

# --- STOP SERVER ---
# This may be called from the update/backup subshells, where the inherited
# $SERVER_PID goes stale after the first maintenance restart and `wait` cannot
# reap a process that is not a child of the current shell. We therefore track
# the live PID in a file and poll for actual process exit (escalating to
# SIGKILL after $SERVER_STOP_TIMEOUT) so callers always wait for the old
# server to fully die before running SteamCMD or a backup.
stop_server() {
    local pid stop_timeout="${SERVER_STOP_TIMEOUT:-120}" waited=0
    pid=$(cat "$SERVER_PID_FILE" 2>/dev/null || echo "${SERVER_PID:-}")
    [ -n "$pid" ] || return 0
    if ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    log "=== Stopping server (pid $pid) ==="
    kill "$pid" 2>/dev/null || true

    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$stop_timeout" ]; then
            log "Server did not stop within ${stop_timeout}s — sending SIGKILL"
            kill -9 "$pid" 2>/dev/null || true
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
}

# --- CLEAN OLD BACKUPS ---
cleanup_backups() {
    log "=== Cleaning backups older than $BACKUP_RETENTION_DAYS days ==="
    find "$BACKUPDIR" -maxdepth 1 -mindepth 1 -type d -mtime +$BACKUP_RETENTION_DAYS -exec rm -rf {} \;
}

# --- BACKUP SAVES ---
backup_saves() {
    SAVES_DIR="$SERVERDIR/RSDragonwilds/Saved/SaveGames"
    if [ -d "$SAVES_DIR" ]; then
        TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
        BACKUP_SAVE="$BACKUPDIR/SaveGames_$TIMESTAMP"
        cp -r "$SAVES_DIR" "$BACKUP_SAVE"
        log "SaveGames backed up to $BACKUP_SAVE"
    fi
}

# --- PARSE ANY SCHEDULE TIME (12-hour format) ---
# Usage: parse_schedule_time "3:00 AM"  →  "3 0"
#        parse_schedule_time "4:30 PM"  →  "16 30"
parse_schedule_time() {
    local time_str="$1"
    local hour minute ampm

    hour=$(echo "$time_str" | sed 's/^\([0-9]*\):.*/\1/' | tr -d ' ')
    minute=$(echo "$time_str" | sed 's/.*:\([0-9]*\).*/\1/' | tr -d ' ')
    ampm=$(echo "$time_str" | sed 's/.*\([AP]M\).*/\1/' | tr -d ' ')

    # Force base-10 so leading zeros (e.g. "09") don't trigger octal errors in arithmetic
    hour=$((10#$hour))
    minute=$((10#$minute))

    if [ "$ampm" = "PM" ] && [ "$hour" -ne 12 ]; then
        hour=$((hour + 12))
    elif [ "$ampm" = "AM" ] && [ "$hour" -eq 12 ]; then
        hour=0
    fi

    echo "$hour $minute"
}

# --- LAST-ACTIVITY TIMESTAMP ---
# Written atomically and read defensively: a truncated/empty file would
# otherwise break the arithmetic below (and, under set -e, the container).
record_activity() {
    local tmp="${LAST_ACTIVITY_FILE}.tmp"
    date +%s > "$tmp" && mv "$tmp" "$LAST_ACTIVITY_FILE"
}

read_last_activity() {
    local now value
    now=$(date +%s)
    value=$(cat "$LAST_ACTIVITY_FILE" 2>/dev/null || true)
    case "$value" in
        ''|*[!0-9]*) echo "$now" ;;
        *) echo "$value" ;;
    esac
}

# --- CHECK IF SERVER IS IDLE (no players + 360s since last activity) ---
# Returns 0 (true) if idle, 1 (false) if not
is_idle() {
    local now last_activity idle player_count
    now=$(date +%s)
    last_activity=$(read_last_activity)
    idle=$((now - last_activity))
    player_count=$(read_count)

    if [ "$player_count" -eq 0 ] && [ "$idle" -ge "$IDLE_WAIT" ]; then
        return 0
    fi
    return 1
}

# --- WAIT UNTIL IDLE (blocking, checks every 60s, logs reason) ---
wait_for_idle() {
    local label="${1:-Operation}"
    while true; do
        local now last_activity idle player_count
        now=$(date +%s)
        last_activity=$(read_last_activity)
        idle=$((now - last_activity))
        player_count=$(read_count)

        if [ "$player_count" -eq 0 ] && [ "$idle" -ge "$IDLE_WAIT" ]; then
            log "$label: Server is idle. Proceeding."
            return 0
        fi

        if [ "$player_count" -gt 0 ]; then
            log "$label: $player_count player(s) online — waiting for them to leave before proceeding..."
        else
            log "$label: Waiting for idle timeout... (${idle}s / ${IDLE_WAIT}s elapsed)"
        fi
        sleep 60
    done
}

# --- RUN DAILY BACKUP ---
run_daily_backup() {
    log "=== Scheduled daily backup time reached ==="
    send_discord "📦 Scheduled daily backup starting — waiting for server idle..."

    wait_for_idle "Daily Backup"

    log "=== Stopping server for daily backup ==="
    touch "$BACKUP_IN_PROGRESS_FILE"
    stop_server

    log "=== Backing up SaveGames ==="
    backup_saves
    cleanup_backups

    send_discord "✅ Daily backup completed — restarting server."

    # Release the main loop to restart the server
    rm -f "$BACKUP_IN_PROGRESS_FILE"
}

# --- RUN UPDATE ---
# Returns 0 when the server is up to date (or the check was inconclusive),
# and 1 when an update was attempted but could not be verified. The update
# loop uses that status to back off instead of retrying (and restarting the
# server) every UPDATE_TIME.
run_update() {
    local manifest="$SERVERDIR/steamapps/appmanifest_$APPID.acf"
    local appinfo_tmp local_build remote_build current_build
    local update_succeeded=false update_verified=false

    log "=== Backing up config ==="
    [ -f "$CONFIGFILE" ] && cp "$CONFIGFILE" "$BACKUPDIR/DedicatedServer.ini"

    log "=== Checking for updates ==="
    local_build=$(parse_manifest_buildid "$manifest" 2>/dev/null || echo "unknown")
    log "Local build: $local_build"

    # Refresh SteamCMD's cached app info before reading the published build.
    # Without +app_info_update 1 the cache can report an outdated build and
    # make app_update a no-op even though Steam has published a newer one.
    appinfo_tmp=$(mktemp "${TMPDIR:-/tmp}/dragonwilds-appinfo.XXXXXX")
    "$STEAMCMD" \
        +login anonymous \
        +app_info_update 1 \
        +app_info_print $APPID \
        +quit > "$appinfo_tmp" 2>&1 || true
    remote_build=$(parse_appinfo_buildid "$appinfo_tmp" public 2>/dev/null || true)
    rm -f "$appinfo_tmp"
    log "Remote build: ${remote_build:-unknown}"

    if [ -z "$remote_build" ]; then
        log "Could not determine remote build ID — skipping update check"
        return 0
    fi

    if [ "$local_build" = "$remote_build" ]; then
        log "Server is up to date (build $local_build) — no update needed"
        return 0
    fi

    # LAST_APPLIED_BUILD is only written after a *verified* update. Older
    # versions recorded it whenever SteamCMD exited 0, which made the wrapper
    # skip further attempts while still running the old build (issue #17).
    log "Update available (local: $local_build → remote: $remote_build) — running SteamCMD"
    send_discord "🛠️ Dragonwilds server update detected (build $remote_build) — waiting for idle before updating..."

    wait_for_idle "Update"

    # Signal the main loop that the server is being stopped intentionally so it
    # waits for us to finish rather than exiting the container (which would
    # SIGKILL this subshell before steamcmd completes and we can write files).
    touch "$UPDATE_IN_PROGRESS_FILE"

    stop_server

    for i in {1..5}; do
        log "SteamCMD attempt $i..."
        "$STEAMCMD" \
            +force_install_dir "$SERVERDIR" \
            +login anonymous \
            +app_info_update 1 \
            +app_update $APPID validate \
            +quit && update_succeeded=true && break
        log "SteamCMD failed, retrying in 5 seconds..."
        sleep 5
    done

    log "=== Restoring config ==="
    [ -f "$BACKUPDIR/DedicatedServer.ini" ] && cp "$BACKUPDIR/DedicatedServer.ini" "$CONFIGFILE"

    # Never trust SteamCMD's exit status alone. Re-read the installed manifest
    # and only record success when the build actually changed.
    current_build=$(parse_manifest_buildid "$manifest" 2>/dev/null || echo "unknown")
    if [ "$current_build" = "$remote_build" ]; then
        update_verified=true
        echo "$remote_build" > "$LAST_APPLIED_BUILD_FILE"
        log "Update verified — local build is now $current_build"
    elif [ "$update_succeeded" = "true" ]; then
        log "WARNING: SteamCMD reported success but the local build is still $current_build (expected $remote_build)."
        log "         SteamCMD's cached app info is probably stale; the server will keep running the old build."
        log "         Retrying later with backoff. If this persists, remove $manifest and restart the container."
    else
        log "WARNING: SteamCMD failed after 5 attempts — update was not applied (local build: $current_build)"
    fi

    if [ "$BACKUP_AFTER_UPDATE" = "true" ]; then
        log "=== Backing up SaveGames (post-update) ==="
        backup_saves
        cleanup_backups
    else
        log "=== Post-update backup skipped (BACKUP_AFTER_UPDATE=false) ==="
    fi

    if [ "$update_verified" = "true" ]; then
        send_discord "✅ Dragonwilds server updated to build $remote_build — restarting server."
    else
        send_discord "⚠️ Dragonwilds update to build $remote_build could not be applied (still on $current_build). Restarting the existing server and retrying later."
    fi

    # Release the main loop to restart the server
    rm -f "$UPDATE_IN_PROGRESS_FILE"

    [ "$update_verified" = "true" ]
}

# --- MONITOR PLAYERS ---
# Runs in a subshell (background). Uses temp files for shared state since
# associative arrays cannot cross subshell boundaries.
monitor_players() {
    local LOG="$SERVERDIR/RSDragonwilds/Saved/Logs/RSDragonwilds.log"
    local chunk="$PLAYER_CHUNK_FILE"

    log "Waiting for server log file..."
    while [ ! -f "$LOG" ] || [ ! -s "$LOG" ]; do
        sleep 1
    done
    sleep 2

    # The server has just started, so nobody is online yet. Start reading at
    # the current end of the log — it only contains startup output.
    local LAST_READ
    LAST_READ=$(wc -l < "$LOG")

    players_reset
    [ -f "$LAST_ACTIVITY_FILE" ] || record_activity

    local log_inode
    log_inode=$(stat -c %i "$LOG")
    log "Player monitor started at line $LAST_READ (inode: $log_inode)"

    : > "$chunk"
    trap 'rm -f "$PLAYER_CHUNK_FILE"' EXIT

    while true; do
        local current_inode
        current_inode=$(stat -c %i "$LOG" 2>/dev/null || echo "$log_inode")

        if [ "$current_inode" != "$log_inode" ]; then
            log "Log file recreated (server restarted) — resetting monitor"
            LAST_READ=0
            log_inode=$current_inode
            record_activity
            players_reset
        fi

        local TOTAL_LINES
        # If the log is momentarily missing, keep the previous position and
        # retry next poll instead of letting set -e kill the monitor.
        TOTAL_LINES=$(wc -l < "$LOG" 2>/dev/null || echo "$LAST_READ")

        # A log that shrank was truncated in place rather than replaced.
        # Resume from the top, otherwise events are ignored until the file
        # grows past the old line count.
        if [ "$TOTAL_LINES" -lt "$LAST_READ" ]; then
            log "Log file truncated — resetting monitor"
            LAST_READ=0
            players_reset
        fi

        if [ "$TOTAL_LINES" -gt "$LAST_READ" ]; then
            # Read from an absolute line offset so lines written between the
            # wc above and this read are neither skipped nor processed twice
            # (tail -n N would shift the window and duplicate events).
            # A failed read leaves an empty chunk, so we simply retry next poll.
            tail -n "+$((LAST_READ + 1))" "$LOG" > "$chunk" 2>/dev/null || true

            local event kind name
            while IFS= read -r event; do
                kind=$(printf '%s\n' "$event" | cut -f1)
                name=$(printf '%s\n' "$event" | cut -f3)
                case "$kind" in
                    join)
                        record_activity
                        log "Player connected: $name (online: $(read_count))"
                        send_discord "🟢 Player connected: $name"
                        ;;
                    leave)
                        record_activity
                        log "Player disconnected: $name (online: $(read_count))"
                        send_discord "🔴 Player disconnected: $name"
                        ;;
                esac
            done < <(process_player_log_chunk "$chunk")

            # Advance by the number of complete lines actually read. A partial
            # trailing line is re-read next poll; add/remove are idempotent, so
            # that cannot double-count or re-notify.
            local read_lines
            read_lines=$(wc -l < "$chunk")
            LAST_READ=$((LAST_READ + read_lines))
        fi

        sleep "$PLAYER_CHECK_INTERVAL"
    done &
}

# --- MAIN ---
echo "" >> "$LOGFILE"
echo "===== Container start $(date '+%Y-%m-%d %H:%M:%S') =====" >> "$LOGFILE"
log "=== Starting Dragonwilds Server ==="
log "Config: AUTO_UPDATE=$ENABLE_AUTO_UPDATE, UPDATE_TIME=${UPDATE_TIME}s, BACKUP_AFTER_UPDATE=$BACKUP_AFTER_UPDATE, BACKUP_DAILY=$BACKUP_DAILY, BACKUP_TIME=$BACKUP_TIME"

# Remove any stale maintenance flags left by a previously killed container
rm -f "$UPDATE_IN_PROGRESS_FILE" "$BACKUP_IN_PROGRESS_FILE" "$SERVER_PID_FILE" "$PLAYER_CHUNK_FILE"

# Install server files if not present (first run or missing binary)
BINARY="$SERVERDIR/RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping"
if [ ! -f "$BINARY" ]; then
    log "Server binary not found — running initial SteamCMD install"
    if ! install_or_verify_server; then
        log "ERROR: server install failed — exiting so Docker can retry the container"
        exit 1
    fi
fi

prepare_dedicated_server_ini
if ! grep -qE "^[[:space:]]*OwnerId=[^[:space:]]+" "$CONFIGFILE"; then
    log "⚠️  WARNING: OwnerId is not set in DedicatedServer.ini — no player will have admin on this server."
    log "            Set OWNER_ID in your .env (your in-game \"My Player Id\") and restart the container."
fi
start_server
monitor_players

# =============================================================================
# UPDATE LOOP — separate subprocess
# Checks for updates every UPDATE_TIME seconds (no once-per-day cap).
# =============================================================================
if [ "$ENABLE_AUTO_UPDATE" = "true" ]; then
    log "Auto-update enabled — checking every ${UPDATE_TIME}s"
    (
        update_failures=0
        while true; do
            # Back off after a failed/unverified update so a stale SteamCMD
            # cache does not restart the server every UPDATE_TIME forever.
            if [ "$update_failures" -eq 0 ]; then
                sleep "$UPDATE_TIME"
            else
                retry_delay=$(update_retry_delay "$update_failures" "$UPDATE_TIME" "$UPDATE_BACKOFF_MAX")
                log "Waiting ${retry_delay}s before the next update attempt (failure #${update_failures})"
                sleep "$retry_delay"
            fi
            log "=== Running scheduled update check ==="
            if run_update; then
                update_failures=0
            else
                update_failures=$((update_failures + 1))
                log "WARNING: update was not applied — backing off before the next attempt"
            fi
        done
    ) &
    UPDATE_LOOP_PID=$!
fi

# =============================================================================
# BACKUP LOOP — separate subprocess
# Polls every POLL_INTERVAL seconds and fires once per day at BACKUP_TIME.
# =============================================================================
if [ "$BACKUP_DAILY" = "true" ]; then
    log "Daily backup scheduled at $BACKUP_TIME (idle required: ${IDLE_WAIT}s)"
    (
        while true; do
            today=$(date +%Y-%m-%d)
            last_backup_date=$(cat "$LAST_BACKUP_DATE_FILE" 2>/dev/null || echo "")

            if [ "$today" != "$last_backup_date" ]; then
                current_hour=$(date +%-H)
                current_minute=$(date +%-M)
                current_total=$((current_hour * 60 + current_minute))

                backup_parsed=$(parse_schedule_time "$BACKUP_TIME")
                backup_hour=$(echo "$backup_parsed" | cut -d' ' -f1)
                backup_minute=$(echo "$backup_parsed" | cut -d' ' -f2)
                backup_total=$((backup_hour * 60 + backup_minute))

                if [ "$current_total" -ge "$backup_total" ]; then
                    if is_idle; then
                        run_daily_backup
                        echo "$today" > "$LAST_BACKUP_DATE_FILE"
                    else
                        player_count=$(read_count)
                        if [ "$player_count" -gt 0 ]; then
                            log "Backup: $player_count player(s) online — retrying in ${POLL_INTERVAL}s..."
                        else
                            now=$(date +%s)
                            last_activity=$(read_last_activity)
                            idle=$((now - last_activity))
                            log "Backup: Waiting for idle timeout (${idle}s / ${IDLE_WAIT}s) — retrying in ${POLL_INTERVAL}s..."
                        fi
                    fi
                fi
            fi

            sleep "$POLL_INTERVAL"
        done
    ) &
    BACKUP_LOOP_PID=$!
fi

# Keep the container alive.  When the server is stopped intentionally (update
# or backup), the background subshell sets an in-progress flag before calling
# stop_server.  We detect that here, wait for the operation to finish, then
# restart the server — rather than letting the container exit and getting
# SIGKILL'd mid-steamcmd by the kernel (PID 1 death kills the whole namespace).
while true; do
    wait "$SERVER_PID" || true

    if [ -f "$UPDATE_IN_PROGRESS_FILE" ] || [ -f "$BACKUP_IN_PROGRESS_FILE" ]; then
        log "Server stopped for scheduled maintenance — waiting for completion..."
        MAINTENANCE_WAIT=0
        while [ -f "$UPDATE_IN_PROGRESS_FILE" ] || [ -f "$BACKUP_IN_PROGRESS_FILE" ]; do
            sleep 5
            MAINTENANCE_WAIT=$((MAINTENANCE_WAIT + 5))
            if [ "$MAINTENANCE_WAIT" -ge 3600 ]; then
                log "WARNING: Maintenance appears stuck after 1h — forcing restart"
                rm -f "$UPDATE_IN_PROGRESS_FILE" "$BACKUP_IN_PROGRESS_FILE"
                break
            fi
        done
        log "Maintenance complete — restarting server"
        start_server
        # monitor_players detects the recreated log and resets its state
    else
        log "Server exited unexpectedly — container stopping"
        break
    fi
done