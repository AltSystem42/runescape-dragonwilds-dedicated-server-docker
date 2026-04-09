# Dragonwilds Dedicated Server Docker Image

![Docker Pulls](https://img.shields.io/docker/pulls/andyaltsys/dragonwilds-dedicated-server)
![GitHub Release](https://img.shields.io/github/v/release/AltSystem42/dragonwilds-dedicated-server-docker)
![GitHub Issues](https://img.shields.io/github/issues/AltSystem42/dragonwilds-dedicated-server-docker)
![License](https://img.shields.io/github/license/AltSystem42/dragonwilds-dedicated-server-docker)
![Docker Build](https://github.com/AltSystem42/dragonwilds-dedicated-server-docker/actions/workflows/docker-build.yml/badge.svg)

A production-ready Docker container for running a dedicated RuneScape: Dragonwilds game server with automated updates, scheduled backups, player monitoring, and Discord notifications.

This image installs and runs the official RuneScape: Dragonwilds Dedicated Server (Steam App ID 4019830) using SteamCMD, and keeps it updated automatically.

## What This Actually Installs

This image uses **SteamCMD** to download and install the **official RuneScape: Dragonwilds Dedicated Server** (Steam AppID: `4019830`). The dedicated server is a separate product distributed by Steam — this container simply automates running and maintaining it.

The image includes:
- Ubuntu 24.04 base with 32-bit compatibility libraries
- SteamCMD for server installation and updates
- Entry point script that orchestrates updates, backups, and monitoring

## Behavior at Startup

When the container starts, the entrypoint script (`scripts/entrypoint-wrapper.sh`) performs these steps:

1. **Server Installation/Update** — If no server files exist, SteamCMD downloads the Dragonwilds dedicated server. On subsequent starts, SteamCMD checks for updates.
2. **Server Launch** — Starts the dedicated server on the configured UDP port
3. **Player Monitoring** — Continuously watches the server log for player connections/disconnections
4. **Idle Monitoring** — Tracks the last player activity timestamp to determine when the server is idle

### Scheduled Tasks (run when server is idle for 6+ minutes)

- **Auto-updates** — Checks for SteamCMD updates hourly (configurable)
- **Daily backups** — At configured time, stops server, backs up SaveGames, restarts
- **Post-update backups** — After each server update, automatically backs up saves

All backups and updates **skip if players are present** to avoid interrupting gameplay.

## Feature Implementation

The following features are implemented in `scripts/entrypoint-wrapper.sh`:

- **Auto-updates** — [Lines 141-186](scripts/entrypoint-wrapper.sh#L141) — Uses SteamCMD to check and install updates
- **Daily backups** — [Lines 113-138](scripts/entrypoint-wrapper.sh#L113) — Scheduled backup at configured time
- **Post-update backups** — [Lines 173-179](scripts/entrypoint-wrapper.sh#L173) — Backs up after each update
- **Player monitoring** — [Lines 189-242](scripts/entrypoint-wrapper.sh#L189) — Watches server log for connections
- **Discord notifications** — [Lines 32-37](scripts/entrypoint-wrapper.sh#L32) — Sends webhook alerts

## Version v0.1.0

This release includes:
- Core server automation via SteamCMD
- Daily and post-update backup functionality
- Player connection monitoring
- Discord webhook notifications (optional)
- Config preservation across updates
- Idle-time aware backup/update logic

## Behind the Scenes

- Installs Dragonwilds Dedicated Server via SteamCMD (AppID 4019830)
- Runs the server on container startup
- Monitors player connections via server log parsing
- Performs backups before shutdown when no players are present
- Sends Discord alerts via webhook when configured

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
  andyaltsys/dragonwilds-dedicated-server:latest
```

### Docker Compose

```yaml
services:
  dragonwilds:
    image: andyaltsys/dragonwilds-dedicated-server:latest
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
    image: andyaltsys/dragonwilds-dedicated-server:latest
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
  andyaltsys/dragonwilds-dedicated-server:latest
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
  andyaltsys/dragonwilds-dedicated-server:latest
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
  andyaltsys/dragonwilds-dedicated-server:latest
```

## License

MIT License - See LICENSE file for details.