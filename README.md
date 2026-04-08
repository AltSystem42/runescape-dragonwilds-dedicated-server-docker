# Dragonwilds Dedicated Server Docker Image

A Docker container for running a dedicated Dragonwilds game server with automated updates, backups, and Discord notifications.

## Features

- **Auto-updates**: Automatically checks for and installs server updates (hourly by default)
- **Daily backups**: Scheduled backups at a configurable time
- **Post-update backups**: Automatic backup after each server update
- **Player monitoring**: Tracks player connections/disconnections
- **Discord notifications**: Alerts for updates, backups, and player events
- **Config preservation**: Keeps your server configuration across updates

## Quick Start

### Docker Run

```bash
docker run -d \
  --name dragonwilds \
  -p 7777:7777/udp \
  -e SERVER_PORT=7777 \
  -e TZ=America/New_York \
  -e BACKUP_TIME="3:00 AM" \
  -v ./server-data:/home/ubuntu/Steam \
  andyaltsys/dragonwilds:latest
```

### Docker Compose

```yaml
services:
  dragonwilds:
    image: andyaltsys/dragonwilds:latest
    container_name: dragonwilds
    ports:
      - "7777:7777/udp"
    environment:
      - SERVER_PORT=7777
      - TZ=America/New_York
      - BACKUP_TIME="3:00 AM"
      - BACKUP_DAILY=true
      - BACKUP_AFTER_UPDATE=true
      - ENABLE_AUTO_UPDATE=true
    volumes:
      - ./server-data:/home/ubuntu/Steam
    restart: unless-stopped
```

### Using .env File

Create a `.env` file:

```env
SERVER_PORT=7777
TZ=America/New_York
BACKUP_TIME="3:00 AM"
BACKUP_DAILY=true
BACKUP_AFTER_UPDATE=true
ENABLE_AUTO_UPDATE=true
BACKUP_RETENTION_DAYS=30
ENABLE_DISCORD_NOTIF=false
DISCORD_WEBHOOK_URL=
```

Then update docker-compose.yml to use `env_file`:

```yaml
services:
  dragonwilds:
    image: andyaltsys/dragonwilds:latest
    container_name: dragonwilds
    ports:
      - "7777:7777/udp"
    env_file:
      - .env
    volumes:
      - ./server-data:/home/ubuntu/Steam
    restart: unless-stopped
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SERVER_PORT` | 7777 | UDP port for server connections |
| `TZ` | UTC | Timezone for scheduled backups |
| `ENABLE_AUTO_UPDATE` | true | Enable automatic server updates |
| `UPDATE_TIME` | 3600 | Seconds between update checks (default: 1 hour) |
| `BACKUP_AFTER_UPDATE` | true | Backup saves after each update |
| `BACKUP_DAILY` | true | Run daily scheduled backup |
| `BACKUP_TIME` | 3:00 AM | Daily backup time (12-hour format with AM/PM) |
| `BACKUP_RETENTION_DAYS` | 30 | Days to keep backups |
| `IDLE_WAIT` | 360 | Seconds to wait for no players before update/backup (default: 6 min) |
| `ENABLE_DISCORD_NOTIF` | false | Enable Discord webhook notifications |
| `DISCORD_WEBHOOK_URL` | (empty) | Discord webhook URL |

## Volume Mounts

| Path | Description |
|------|-------------|
| `/home/ubuntu/Steam` | Server files, saves, and backups |

## Examples

### With Discord Notifications

```bash
docker run -d \
  --name dragonwilds \
  -p 7777:7777/udp \
  -e SERVER_PORT=7777 \
  -e ENABLE_DISCORD_NOTIF=true \
  -e DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/xxx \
  -e BACKUP_TIME="3:00 AM" \
  -e TZ=America/New_York \
  -v ./server-data:/home/ubuntu/Steam \
  andyaltsys/dragonwilds:latest
```

### Disable All Backups

```bash
docker run -d \
  --name dragonwilds \
  -p 7777:7777/udp \
  -e SERVER_PORT=7777 \
  -e BACKUP_AFTER_UPDATE=false \
  -e BACKUP_DAILY=false \
  -v ./server-data:/home/ubuntu/Steam \
  andyaltsys/dragonwilds:latest
```

### Disable Auto-Update, Keep Daily Backup Only

```bash
docker run -d \
  --name dragonwilds \
  -p 7777:7777/udp \
  -e SERVER_PORT=7777 \
  -e ENABLE_AUTO_UPDATE=false \
  -e BACKUP_DAILY=true \
  -e BACKUP_TIME="3:00 AM" \
  -e TZ=Europe/London \
  -v ./server-data:/home/ubuntu/Steam \
  andyaltsys/dragonwilds:latest
```

## Accessing Server Files

The server files are stored in the mounted volume at:
- **Saves**: `/home/ubuntu/Steam/RSDragonwilds/Saved/SaveGames`
- **Config**: `/home/ubuntu/Steam/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini`
- **Logs**: `/home/ubuntu/Steam/RSDragonwilds/Saved/Logs/`
- **Backups**: `/home/ubuntu/Steam/backup/`

## Logs

View container logs:
```bash
docker logs dragonwilds
```

View entrypoint script logs (inside container):
```bash
docker exec dragonwilds cat /home/ubuntu/Steam/RSDragonwilds/Saved/Logs/entrypoint.log
```

## Behavior

- **Update logic**: Waits for 6 minutes of idle time (no players) before running updates
- **Backup logic**: Scheduled daily backup waits for idle time, stops server, backs up saves, restarts
- **Both backups and updates are skipped if players are active**
- Post-update backups run regardless of scheduled backup time