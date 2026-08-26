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
SERVERDIR="${SERVERDIR:-/home/ubuntu/Steam}"
CONFIGFILE="$SERVERDIR/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini"
BACKUPDIR="$SERVERDIR/backup"
LOGFILE="$SERVERDIR/RSDragonwilds/Saved/Logs/entrypoint.log"
LAST_ACTIVITY_FILE="$SERVERDIR/.last_activity"
PLAYER_COUNT_FILE="$SERVERDIR/.player_count"
SERVER_RESTART_FILE="$SERVERDIR/.server_restart"
LAST_BACKUP_DATE_FILE="$SERVERDIR/.last_backup_date"
LAST_APPLIED_BUILD_FILE="$SERVERDIR/.last_applied_build"
UPDATE_IN_PROGRESS_FILE="$SERVERDIR/.update_in_progress"
BACKUP_IN_PROGRESS_FILE="$SERVERDIR/.backup_in_progress"
SERVER_PORT="${SERVER_PORT:-7777}"
ENABLE_AUTO_UPDATE="${ENABLE_AUTO_UPDATE:-true}"
UPDATE_TIME="${UPDATE_TIME:-3600}"              # How often (seconds) to check for updates (e.g. 3600 = every hour)
ENABLE_DISCORD_NOTIF="${ENABLE_DISCORD_NOTIF:-false}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
IDLE_WAIT="${IDLE_WAIT:-360}"
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

HOME=/home/ubuntu
mkdir -p "$BACKUPDIR" "$SERVERDIR/steamapps" "$(dirname "$LOGFILE")"

[ -f "$LOGFILE" ] && rm -f "$LOGFILE"

log() {
    echo "$1" | tee -a "$LOGFILE"
}

# --- FUNCTION TO SEND DISCORD NOTIFICATION ---
send_discord() {
    if [ "$ENABLE_DISCORD_NOTIF" = "true" ] && [ -n "$DISCORD_WEBHOOK_URL" ]; then
        curl -s -X POST -H "Content-Type: application/json" \
            -d "{\"content\":\"$1\"}" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1
    fi
}

# --- INSTALL / VERIFY SERVER FILES VIA STEAMCMD ---
install_or_verify_server() {
    log "=== Installing/verifying server files via SteamCMD ==="
    send_discord "📥 Installing Dragonwilds Dedicated Server — this may take a while..."
    for i in {1..5}; do
        log "SteamCMD attempt $i..."
        /home/ubuntu/steamcmd/steamcmd.sh \
            +force_install_dir "$SERVERDIR" \
            +login anonymous \
            +app_update $APPID validate \
            +quit && break
        log "SteamCMD failed, retrying in 5 seconds..."
        sleep 5
    done
    log "=== SteamCMD install/verify complete ==="
    send_discord "✅ Dragonwilds Dedicated Server installed."
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

        # key present?
        if [[ -z "$key" ]]; then echo "Error: Key required."; return 1; fi

        # kvp present?
        if grep -qE "^[[:space:]]*$key=" "$CONFIGFILE"; then
            # value present?
            if [[ ! -z "$new_value" ]]; then
                # replace key
                sed -i.bak -E "s|^([[:space:]]*$key=).*|\1$new_value|" "$CONFIGFILE"
            fi
        else # append key
            echo "$key=$new_value" >> "$CONFIGFILE"
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
    set_key "AdminPassword"    "${ADMIN_PASSWORD:-$(openssl rand -hex 16 | tr 'a-f' 'A-F')}"
    set_key "ServerName"       "${SERVER_NAME:-Server-$(date +%s)}"
    set_key "DefaultWorldName" "${DEFAULT_WORLD_NAME:-World-$(date +%s)}"
    set_key "WorldPassword"    "${WORLD_PASSWORD}"

    # private function cleanup
    unset -f set_key
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
}

# --- STOP SERVER ---
stop_server() {
    if ps -p "$SERVER_PID" > /dev/null 2>&1; then
        log "=== Stopping server ==="
        kill "$SERVER_PID"
        wait "$SERVER_PID" || true
    fi
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

# --- CHECK IF SERVER IS IDLE (no players + 360s since last activity) ---
# Returns 0 (true) if idle, 1 (false) if not
is_idle() {
    local now last_activity idle player_count
    now=$(date +%s)
    last_activity=$(cat "$LAST_ACTIVITY_FILE" 2>/dev/null || echo "$now")
    idle=$((now - last_activity))
    player_count=$(cat "$PLAYER_COUNT_FILE" 2>/dev/null || echo "0")

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
        last_activity=$(cat "$LAST_ACTIVITY_FILE" 2>/dev/null || echo "$now")
        idle=$((now - last_activity))
        player_count=$(cat "$PLAYER_COUNT_FILE" 2>/dev/null || echo "0")

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
run_update() {
    log "=== Backing up config ==="
    [ -f "$CONFIGFILE" ] && cp "$CONFIGFILE" "$BACKUPDIR/DedicatedServer.ini"

    log "=== Checking for updates ==="
    LOCAL_BUILD=$(grep '"buildid"' "$SERVERDIR/steamapps/appmanifest_$APPID.acf" 2>/dev/null | head -n1 | sed 's/.*"\([0-9]*\)".*/\1/')
    LOCAL_BUILD="${LOCAL_BUILD:-unknown}"
    log "Local build: $LOCAL_BUILD"

    REMOTE_BUILD=$(/home/ubuntu/steamcmd/steamcmd.sh +login anonymous +app_info_print $APPID +quit \
        | grep '"buildid"' | head -n1 | sed 's/.*"\([0-9]*\)".*/\1/')
    log "Remote build: $REMOTE_BUILD"

    if [ -z "$REMOTE_BUILD" ]; then
        log "Could not determine remote build ID — skipping update check"
        return
    fi

    LAST_APPLIED_BUILD=$(cat "$LAST_APPLIED_BUILD_FILE" 2>/dev/null || echo "")

    if [ "$LOCAL_BUILD" = "$REMOTE_BUILD" ]; then
        log "Server is up to date (build $LOCAL_BUILD) — no update needed"
        return
    fi

    if [ "$REMOTE_BUILD" = "$LAST_APPLIED_BUILD" ] && [ "$LOCAL_BUILD" = "$LAST_APPLIED_BUILD" ]; then
        log "Update to build $REMOTE_BUILD was already applied — skipping"
        return
    fi

    log "Update available (local: $LOCAL_BUILD → remote: $REMOTE_BUILD) — running SteamCMD"
    send_discord "🛠️ Dragonwilds server update detected (build $REMOTE_BUILD) — waiting for idle before updating..."

    wait_for_idle "Update"

    # Signal the main loop that the server is being stopped intentionally so it
    # waits for us to finish rather than exiting the container (which would
    # SIGKILL this subshell before steamcmd completes and we can write files).
    touch "$UPDATE_IN_PROGRESS_FILE"

    stop_server

    UPDATE_SUCCEEDED=false
    for i in {1..5}; do
        log "SteamCMD attempt $i..."
        /home/ubuntu/steamcmd/steamcmd.sh \
            +force_install_dir "$SERVERDIR" \
            +login anonymous \
            +app_update $APPID validate \
            +quit && UPDATE_SUCCEEDED=true && break
        log "SteamCMD failed, retrying in 5 seconds..."
        sleep 5
    done

    log "=== Restoring config ==="
    [ -f "$BACKUPDIR/DedicatedServer.ini" ] && cp "$BACKUPDIR/DedicatedServer.ini" "$CONFIGFILE"

    if [ "$UPDATE_SUCCEEDED" = "true" ]; then
        echo "$REMOTE_BUILD" > "$LAST_APPLIED_BUILD_FILE"
        log "Recorded applied build: $REMOTE_BUILD"
    else
        log "WARNING: SteamCMD failed after 5 attempts — update may be incomplete"
    fi

    if [ "$BACKUP_AFTER_UPDATE" = "true" ]; then
        log "=== Backing up SaveGames (post-update) ==="
        backup_saves
        cleanup_backups
    else
        log "=== Post-update backup skipped (BACKUP_AFTER_UPDATE=false) ==="
    fi

    send_discord "✅ Dragonwilds server updated to build $REMOTE_BUILD — restarting server."

    # Release the main loop to restart the server
    rm -f "$UPDATE_IN_PROGRESS_FILE"
}

# --- MONITOR PLAYERS ---
# Runs in a subshell (background). Uses temp files for shared state since
# associative arrays cannot cross subshell boundaries.
monitor_players() {
    local LOG="$SERVERDIR/RSDragonwilds/Saved/Logs/RSDragonwilds.log"
    local PLAYERS_FILE="$SERVERDIR/.online_players"

    log "Waiting for server log file..."
    while [ ! -f "$LOG" ] || [ ! -s "$LOG" ]; do
        sleep 1
    done
    sleep 2

    local LAST_READ
    if [ -f "$SERVER_RESTART_FILE" ]; then
        rm -f "$SERVER_RESTART_FILE"
        log "Server restarted — resetting log position to 0"
        LAST_READ=0
    else
        LAST_READ=$(wc -l < "$LOG")
    fi

    > "$PLAYERS_FILE"
    echo "0" > "$PLAYER_COUNT_FILE"

    if [ -f "$LAST_ACTIVITY_FILE" ]; then
        : # keep existing timestamp
    else
        date +%s > "$LAST_ACTIVITY_FILE"
    fi

    local log_inode
    log_inode=$(stat -c %i "$LOG")
    log "Player monitor started at line $LAST_READ (inode: $log_inode)"

    while true; do
        local current_inode
        current_inode=$(stat -c %i "$LOG" 2>/dev/null || echo "$log_inode")

        if [ "$current_inode" != "$log_inode" ]; then
            log "Log file recreated (server restarted) — resetting monitor"
            LAST_READ=0
            log_inode=$current_inode
            date +%s > "$LAST_ACTIVITY_FILE"
            > "$PLAYERS_FILE"
            echo "0" > "$PLAYER_COUNT_FILE"
        fi

        local TOTAL_LINES NEW_LINES
        TOTAL_LINES=$(wc -l < "$LOG")
        NEW_LINES=$((TOTAL_LINES - LAST_READ))

        if [ "$NEW_LINES" -gt 0 ]; then
            local line player
            while IFS= read -r line; do
                if [[ "$line" == *"LogNet: Join succeeded:"* ]]; then
                    player=$(echo "$line" | grep -oE 'LogNet: Join succeeded: ([^[:space:]]+)' | sed 's/.*LogNet: Join succeeded: //')
                    if [ -n "$player" ]; then
                        grep -qxF "$player" "$PLAYERS_FILE" 2>/dev/null || echo "$player" >> "$PLAYERS_FILE"
                        local count
                        count=$(wc -l < "$PLAYERS_FILE")
                        echo "$count" > "$PLAYER_COUNT_FILE"
                        date +%s > "$LAST_ACTIVITY_FILE"
                        log "Player connected: $player (online: $count)"
                        send_discord "🟢 Player connected: $player"
                    fi
                fi

                if [[ "$line" == *"LogDominionPlayerController: ClientRequestDisconnect"* ]]; then
                    player=$(echo "$line" | grep -oE 'Character Name\[[^]]+\]' | sed 's/Character Name\[//;s/\]//')
                    if [ -n "$player" ]; then
                        sed -i "/^${player}$/d" "$PLAYERS_FILE"
                        local count
                        count=$(wc -l < "$PLAYERS_FILE")
                        echo "$count" > "$PLAYER_COUNT_FILE"
                        date +%s > "$LAST_ACTIVITY_FILE"
                        log "Player disconnected: $player (online: $count)"
                        send_discord "🔴 Player disconnected: $player"
                    fi
                fi
            done < <(tail -n "$NEW_LINES" "$LOG")
            LAST_READ=$TOTAL_LINES
        fi

        sleep "$PLAYER_CHECK_INTERVAL"
    done &
}

# --- MAIN ---
log "=== Starting Dragonwilds Server ==="
log "Config: AUTO_UPDATE=$ENABLE_AUTO_UPDATE, UPDATE_TIME=${UPDATE_TIME}s, BACKUP_AFTER_UPDATE=$BACKUP_AFTER_UPDATE, BACKUP_DAILY=$BACKUP_DAILY, BACKUP_TIME=$BACKUP_TIME"

# Remove any stale maintenance flags left by a previously killed container
rm -f "$UPDATE_IN_PROGRESS_FILE" "$BACKUP_IN_PROGRESS_FILE"

# Install server files if not present (first run or missing binary)
BINARY="$SERVERDIR/RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping"
if [ ! -f "$BINARY" ]; then
    log "Server binary not found — running initial SteamCMD install"
    install_or_verify_server
fi

prepare_dedicated_server_ini
start_server
monitor_players

# =============================================================================
# UPDATE LOOP — separate subprocess
# Checks for updates every UPDATE_TIME seconds (no once-per-day cap).
# =============================================================================
if [ "$ENABLE_AUTO_UPDATE" = "true" ]; then
    log "Auto-update enabled — checking every ${UPDATE_TIME}s"
    (
        while true; do
            sleep "$UPDATE_TIME"
            log "=== Running scheduled update check ==="
            run_update
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
                        player_count=$(cat "$PLAYER_COUNT_FILE" 2>/dev/null || echo "0")
                        if [ "$player_count" -gt 0 ]; then
                            log "Backup: $player_count player(s) online — retrying in ${POLL_INTERVAL}s..."
                        else
                            now=$(date +%s)
                            last_activity=$(cat "$LAST_ACTIVITY_FILE" 2>/dev/null || echo "$now")
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
        touch "$SERVER_RESTART_FILE"
        start_server
        # monitor_players inode watch handles the new log automatically
    else
        log "Server exited unexpectedly — container stopping"
        break
    fi
done