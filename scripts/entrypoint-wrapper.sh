#!/bin/bash
set -e

# --- ENVIRONMENT VARIABLES ---
APPID=4019830
SERVERDIR="${SERVERDIR:-/home/ubuntu/Steam}"
CONFIGFILE="$SERVERDIR/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini"
BACKUPDIR="$SERVERDIR/backup"
LOGFILE="$SERVERDIR/RSDragonwilds/Saved/Logs/entrypoint.log"
SERVER_PORT="${SERVER_PORT:-7777}"
ENABLE_AUTO_UPDATE="${ENABLE_AUTO_UPDATE:-true}"
UPDATE_TIME="${UPDATE_TIME:-3600}"
ENABLE_DISCORD_NOTIF="${ENABLE_DISCORD_NOTIF:-false}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
IDLE_WAIT=360
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
PLAYER_CHECK_INTERVAL=5
BACKUP_AFTER_UPDATE="${BACKUP_AFTER_UPDATE:-true}"
if [ "$BACKUP_DAILY" = "true" ]; then
    last_backup_date=""
fi
BACKUP_DAILY="${BACKUP_DAILY:-true}"
BACKUP_TIME="${BACKUP_TIME:-3:00 AM}"

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

# --- START SERVER ---
start_server() {
    log "=== Starting Dragonwilds Server on port ${SERVER_PORT} ==="
    cd "$SERVERDIR/RSDragonwilds/Binaries/Linux"
    ./RSDragonwildsServer-Linux-Shipping RSDragonwilds -log -Port="${SERVER_PORT}" &
    SERVER_PID=$!
}

# --- STOP SERVER ---
stop_server() {
    if ps -p "$SERVER_PID" > /dev/null 2>&1; then
        log "=== Stopping server for update ==="
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

# --- PARSE BACKUP TIME (12-hour format) ---
parse_backup_time() {
    local time_str="$BACKUP_TIME"
    local hour minute ampm
    
    hour=$(echo "$time_str" | sed 's/:\([0-9]*\).*/\1/')
    minute=$(echo "$time_str" | sed 's/.*:\([0-9]*\).*/\1/')
    ampm=$(echo "$time_str" | sed 's/.*\([AP]M\).*/\1/')
    
    hour=$(echo "$hour" | tr -d ' ')
    minute=$(echo "$minute" | tr -d ' ')
    ampm=$(echo "$ampm" | tr -d ' ')
    
    if [ "$ampm" = "PM" ] && [ "$hour" -ne 12 ]; then
        hour=$((hour + 12))
    elif [ "$ampm" = "AM" ] && [ "$hour" -eq 12 ]; then
        hour=0
    fi
    
    echo "$hour $minute"
}

# --- RUN DAILY BACKUP ---
run_daily_backup() {
    log "=== Scheduled daily backup time reached ==="
    send_discord "📦 Scheduled daily backup starting..."
    
    log "⏳ Waiting for idle state before backup..."
    while true; do
        now=$(date +%s)
        idle=$((now - last_activity))
        if [ "$idle" -ge "$IDLE_WAIT" ]; then
            log "Server idle for $IDLE_WAIT seconds, safe to backup."
            break
        fi
        sleep 5
    done
    
    log "=== Stopping server for daily backup ==="
    stop_server
    
    log "=== Backing up SaveGames ==="
    backup_saves
    cleanup_backups
    
    log "=== Starting server after daily backup ==="
    start_server
    send_discord "✅ Daily backup completed, server restarted."
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

    if [ "$LOCAL_BUILD" != "$REMOTE_BUILD" ]; then
        log "Update available — running SteamCMD"
        send_discord "🛠️ Dragonwilds server update detected. Updating now..."
        stop_server

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

        log "=== Restoring config ==="
        [ -f "$BACKUPDIR/DedicatedServer.ini" ] && cp "$BACKUPDIR/DedicatedServer.ini" "$CONFIGFILE"

        if [ "$BACKUP_AFTER_UPDATE" = "true" ]; then
            log "=== Backing up SaveGames (post-update) ==="
            backup_saves
            cleanup_backups
        else
            log "=== Post-update backup skipped (BACKUP_AFTER_UPDATE=false) ==="
        fi

        start_server
        send_discord "✅ Dragonwilds server updated and restarted."
    else
        log "Server is up to date — no update needed"
    fi
}

# --- MONITOR PLAYERS ---
monitor_players() {
    LOG="$SERVERDIR/RSDragonwilds/Saved/Logs/RSDragonwilds.log"

    log "Waiting for server log file..."
    while [ ! -f "$LOG" ] || [ ! -s "$LOG" ]; do
        sleep 1
    done

    sleep 2

    declare -A ONLINE_PLAYERS
    LAST_READ=$(wc -l < "$LOG")
    last_activity=$(date +%s)
    log_inode=$(stat -c %i "$LOG")
    log "Player monitor started. Watching for new log lines from line $LAST_READ (inode: $log_inode)"

    while true; do
        current_inode=$(stat -c %i "$LOG" 2>/dev/null || echo "$log_inode")
        if [ "$current_inode" != "$log_inode" ]; then
            log "Log file recreated (server restarted), resetting read position from $LAST_READ to 0..."
            LAST_READ=0
            log_inode=$current_inode
            last_activity=$(date +%s)
            declare -A ONLINE_PLAYERS
            log "Player monitor reset. Watching for new log lines from line 0 (inode: $log_inode)"
        fi

        TOTAL_LINES=$(wc -l < "$LOG")
        NEW_LINES=$((TOTAL_LINES - LAST_READ))
        if [ "$NEW_LINES" -gt 0 ]; then
            tail -n "$NEW_LINES" "$LOG" | while read -r line; do
                if [[ "$line" == *"LogNet: Join succeeded:"* ]]; then
                    player=$(echo "$line" | grep -oE 'LogNet: Join succeeded: ([^[:space:]]+)' | sed 's/.*LogNet: Join succeeded: //')
                    [ -n "$player" ] && ONLINE_PLAYERS["$player"]=1
                    log "Player connected: $player"
                    send_discord "🟢 Player connected: $player"
                    last_activity=$(date +%s)
                fi

                if [[ "$line" == *"LogDomMatcherSession: Player Removed from session"* ]]; then
                    player=$(echo "$line" | sed 's/.*\]-\[//;s/\].*//')
                    if [ -n "$player" ]; then
                        unset ONLINE_PLAYERS["$player"]
                        log "Player disconnected: $player"
                        send_discord "🔴 Player disconnected: $player"
                        last_activity=$(date +%s)
                    fi
                fi
            done
            LAST_READ=$TOTAL_LINES
        fi
        sleep "$PLAYER_CHECK_INTERVAL"
    done &
}

# --- MAIN LOOP ---
log "=== Starting Dragonwilds Server ==="
log "Config: AUTO_UPDATE=$ENABLE_AUTO_UPDATE, BACKUP_AFTER_UPDATE=$BACKUP_AFTER_UPDATE, BACKUP_DAILY=$BACKUP_DAILY, BACKUP_TIME=$BACKUP_TIME"

start_server
monitor_players

if [ "$BACKUP_DAILY" = "true" ]; then
    log "Daily backup scheduled at $BACKUP_TIME"
fi

if [ "$ENABLE_AUTO_UPDATE" = "true" ]; then
    while true; do
        if [ "$BACKUP_DAILY" = "true" ]; then
            while true; do
                parsed=$(parse_backup_time)
                target_hour=$(echo "$parsed" | cut -d' ' -f1)
                target_minute=$(echo "$parsed" | cut -d' ' -f2)
                current_hour=$(date +%-H)
                current_minute=$(date +%-M)
                
                if [ "$current_hour" -eq "$target_hour" ] && [ "$current_minute" -eq "$target_minute" ]; then
                    today=$(date +%Y-%m-%d)
                    if [ "$today" != "$last_backup_date" ]; then
                        now=$(date +%s)
                        idle=$((now - last_activity))
                        if [ "$idle" -ge "$IDLE_WAIT" ]; then
                            run_daily_backup
                            last_backup_date=$(date +%Y-%m-%d)
                        else
                            log "Player active, waiting for idle... (elapsed: ${idle}s of ${IDLE_WAIT}s)"
                        fi
                    fi
                fi
                
                sleep 5
            done
        fi
        
        log "=== Running scheduled update check ==="
        run_update
        
        log "Next check in ${UPDATE_TIME} seconds..."
        sleep "$UPDATE_TIME"
    done
else
    if [ "$BACKUP_DAILY" = "true" ]; then
        while true; do
            while true; do
                parsed=$(parse_backup_time)
                target_hour=$(echo "$parsed" | cut -d' ' -f1)
                target_minute=$(echo "$parsed" | cut -d' ' -f2)
                current_hour=$(date +%-H)
                current_minute=$(date +%-M)
                
                if [ "$current_hour" -eq "$target_hour" ] && [ "$current_minute" -eq "$target_minute" ]; then
                    today=$(date +%Y-%m-%d)
                    if [ "$today" != "$last_backup_date" ]; then
                        now=$(date +%s)
                        idle=$((now - last_activity))
                        if [ "$idle" -ge "$IDLE_WAIT" ]; then
                            run_daily_backup
                            last_backup_date=$(date +%Y-%m-%d)
                        else
                            log "Player active, waiting for idle... (elapsed: ${idle}s of ${IDLE_WAIT}s)"
                        fi
                    fi
                fi
                
                sleep 5
            done
            
            log "Next backup check in ${UPDATE_TIME} seconds..."
            sleep "$UPDATE_TIME"
        done
    else
        log "Auto-update and daily backup disabled. Server running only."
        wait "$SERVER_PID"
    fi
fi