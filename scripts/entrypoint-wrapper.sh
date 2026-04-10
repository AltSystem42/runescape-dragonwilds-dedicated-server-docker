#!/bin/bash
set -e

# --- ENVIRONMENT VARIABLES ---
APPID=4019830
SERVERDIR="${SERVERDIR:-/home/ubuntu/Steam}"
CONFIGFILE="$SERVERDIR/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini"
BACKUPDIR="$SERVERDIR/backup"
LOGFILE="$SERVERDIR/RSDragonwilds/Saved/Logs/entrypoint.log"
LAST_ACTIVITY_FILE="$SERVERDIR/.last_activity"
PLAYER_COUNT_FILE="$SERVERDIR/.player_count"
SERVER_RESTART_FILE="$SERVERDIR/.server_restart"
SERVER_PORT="${SERVER_PORT:-7777}"
ENABLE_AUTO_UPDATE="${ENABLE_AUTO_UPDATE:-true}"
UPDATE_TIME="${UPDATE_TIME:-3600}"
ENABLE_DISCORD_NOTIF="${ENABLE_DISCORD_NOTIF:-false}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
IDLE_WAIT="${IDLE_WAIT:-360}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
PLAYER_CHECK_INTERVAL=5
BACKUP_AFTER_UPDATE="${BACKUP_AFTER_UPDATE:-true}"
UPDATE_DELAY=10
if [ "$BACKUP_DAILY" = "true" ]; then
    last_backup_date=""
    backup_window_date=""
fi
if [ "$ENABLE_AUTO_UPDATE" = "true" ]; then
    update_window_date=""
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
    
    hour=$(echo "$time_str" | sed 's/^\([0-9]*\):.*/\1/')
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

# --- PARSE UPDATE TIME (backup time + delay) ---
parse_update_time() {
    parsed=$(parse_backup_time)
    target_hour=$(echo "$parsed" | cut -d' ' -f1)
    target_minute=$(echo "$parsed" | cut -d' ' -f2)
    
    target_minute=$((target_minute + UPDATE_DELAY))
    if [ "$target_minute" -ge 60 ]; then
        target_hour=$((target_hour + 1))
        target_minute=$((target_minute - 60))
    fi
    
    if [ "$target_hour" -ge 24 ]; then
        target_hour=$((target_hour - 24))
    fi
    
    echo "$target_hour $target_minute"
}

# --- WAIT FOR IDLE STATE ---
wait_for_idle() {
    while true; do
        now=$(date +%s)
        last_activity=$(cat "$LAST_ACTIVITY_FILE" 2>/dev/null || echo "$now")
        idle=$((now - last_activity))
        player_count=$(cat "$PLAYER_COUNT_FILE" 2>/dev/null || echo "0")
        
        if [ "$idle" -ge "$IDLE_WAIT" ] && [ "$player_count" -eq 0 ]; then
            log "Server idle for ${IDLE_WAIT}s with no players."
            return 0
        fi
        
        if [ "$player_count" -gt 0 ]; then
            log "Player(s) online, waiting for idle... (check again in ${IDLE_WAIT}s)"
        else
            log "Waiting for idle time... (${idle}s of ${IDLE_WAIT}s)"
        fi
        sleep "$IDLE_WAIT"
    done
}

# --- RUN DAILY BACKUP ---
run_daily_backup() {
    log "=== Scheduled daily backup time reached ==="
    send_discord "📦 Scheduled daily backup starting..."
    
    log "⏳ Waiting for idle state before backup..."
    wait_for_idle
    
    log "=== Stopping server for daily backup ==="
    stop_server
    
    log "=== Backing up SaveGames ==="
    backup_saves
    cleanup_backups
    
    log "=== Starting server after daily backup ==="
    start_server
    echo "1" > "$SERVER_RESTART_FILE"
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
        
        log "⏳ Waiting for idle state before update..."
        wait_for_idle
        
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

    if [ -f "$SERVER_RESTART_FILE" ]; then
        rm -f "$SERVER_RESTART_FILE"
        log "Server restarted, resetting log position to read fresh..."
        LAST_READ=0
    else
        LAST_READ=$(wc -l < "$LOG")
    fi

    declare -A ONLINE_PLAYERS
    echo "0" > "$PLAYER_COUNT_FILE"
    if [ -f "$LAST_ACTIVITY_FILE" ]; then
        last_activity=$(cat "$LAST_ACTIVITY_FILE")
    else
        last_activity=$(date +%s)
        echo "$last_activity" > "$LAST_ACTIVITY_FILE"
    fi
    log_inode=$(stat -c %i "$LOG")
    log "Player monitor started. Watching for new log lines from line $LAST_READ (inode: $log_inode)"

    while true; do
        current_inode=$(stat -c %i "$LOG" 2>/dev/null || echo "$log_inode")
        if [ "$current_inode" != "$log_inode" ]; then
            log "Log file recreated (server restarted), resetting read position from $LAST_READ to 0..."
            LAST_READ=0
            log_inode=$current_inode
            last_activity=$(date +%s)
            echo "$last_activity" > "$LAST_ACTIVITY_FILE"
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
                    echo "$last_activity" > "$LAST_ACTIVITY_FILE"
                    echo "${#ONLINE_PLAYERS[@]}" > "$PLAYER_COUNT_FILE"
                fi

                if [[ "$line" == *"LogDominionPlayerController: ClientRequestDisconnect"* ]]; then
                    player=$(echo "$line" | grep -oE 'Character Name\[[^]]+\]' | sed 's/Character Name\[//;s/\]//')
                    if [ -n "$player" ]; then
                        unset ONLINE_PLAYERS["$player"]
                        log "Player disconnected: $player"
                        send_discord "🔴 Player disconnected: $player"
                        last_activity=$(date +%s)
                        echo "$last_activity" > "$LAST_ACTIVITY_FILE"
                        echo "${#ONLINE_PLAYERS[@]}" > "$PLAYER_COUNT_FILE"
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
        today=$(date +%Y-%m-%d)
        current_hour=$(date +%-H)
        current_minute=$(date +%-M)
        
        backup_parsed=$(parse_backup_time)
        backup_hour=$(echo "$backup_parsed" | cut -d' ' -f1)
        backup_minute=$(echo "$backup_parsed" | cut -d' ' -f2)
        
        update_parsed=$(parse_update_time)
        update_hour=$(echo "$update_parsed" | cut -d' ' -f1)
        update_minute=$(echo "$update_parsed" | cut -d' ' -f2)
        
        in_backup_window=false
        if [ "$current_hour" -eq "$backup_hour" ] && [ "$current_minute" -eq "$backup_minute" ]; then
            in_backup_window=true
            backup_window_date="$today"
        elif [ "$backup_window_date" = "$today" ]; then
            in_backup_window=true
        fi
        
        in_update_window=false
        if [ "$current_hour" -eq "$update_hour" ] && [ "$current_minute" -eq "$update_minute" ]; then
            in_update_window=true
            update_window_date="$today"
        elif [ "$update_window_date" = "$today" ]; then
            in_update_window=true
        fi
        
        if [ "$BACKUP_DAILY" = "true" ] && [ "$in_backup_window" = "true" ]; then
            if [ "$today" != "$last_backup_date" ]; then
                now=$(date +%s)
                last_activity=$(cat "$LAST_ACTIVITY_FILE" 2>/dev/null || echo "$now")
                idle=$((now - last_activity))
                player_count=$(cat "$PLAYER_COUNT_FILE" 2>/dev/null || echo "0")
                
                if [ "$idle" -ge "$IDLE_WAIT" ] && [ "$player_count" -eq 0 ]; then
                    run_daily_backup
                    last_backup_date=$(date +%Y-%m-%d)
                    backup_window_date=""
                else
                    if [ "$player_count" -gt 0 ]; then
                        log "Backup: Player(s) online, waiting for idle... (elapsed: ${idle}s)"
                    else
                        log "Backup: Waiting for idle time... (${idle}s of ${IDLE_WAIT}s)"
                    fi
                fi
            fi
        fi
        
        if [ "$in_update_window" = "true" ]; then
            now=$(date +%s)
            last_activity=$(cat "$LAST_ACTIVITY_FILE" 2>/dev/null || echo "$now")
            idle=$((now - last_activity))
            player_count=$(cat "$PLAYER_COUNT_FILE" 2>/dev/null || echo "0")
            
            if [ "$idle" -ge "$IDLE_WAIT" ] && [ "$player_count" -eq 0 ]; then
                log "=== Running scheduled update check ==="
                run_update
            else
                if [ "$player_count" -gt 0 ]; then
                    log "Update: Player(s) online, waiting for idle... (elapsed: ${idle}s)"
                else
                    log "Update: Waiting for idle time... (${idle}s of ${IDLE_WAIT}s)"
                fi
            fi
        fi
        
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
                
                today=$(date +%Y-%m-%d)
                
                in_backup_window=false
                if [ "$current_hour" -eq "$target_hour" ] && [ "$current_minute" -eq "$target_minute" ]; then
                    in_backup_window=true
                    backup_window_date="$today"
                elif [ "$backup_window_date" = "$today" ]; then
                    in_backup_window=true
                fi
                
                if [ "$in_backup_window" = "true" ]; then
                    if [ "$today" != "$last_backup_date" ]; then
                        now=$(date +%s)
                        last_activity=$(cat "$LAST_ACTIVITY_FILE" 2>/dev/null || echo "$now")
                        idle=$((now - last_activity))
                        player_count=$(cat "$PLAYER_COUNT_FILE" 2>/dev/null || echo "0")
                        
                        if [ "$idle" -ge "$IDLE_WAIT" ] && [ "$player_count" -eq 0 ]; then
                            run_daily_backup
                            last_backup_date=$(date +%Y-%m-%d)
                            backup_window_date=""
                        else
                            if [ "$player_count" -gt 0 ]; then
                                log "Backup: Player(s) online, waiting for idle... (elapsed: ${idle}s)"
                            else
                                log "Backup: Waiting for idle time... (${idle}s of ${IDLE_WAIT}s)"
                            fi
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