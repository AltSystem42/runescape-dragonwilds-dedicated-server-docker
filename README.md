# Dragonwilds Dedicated Server Docker Image

![Docker Pulls](https://img.shields.io/docker/pulls/andyaltsys/dragonwilds-dedicated-server)
![GitHub Release](https://img.shields.io/github/v/release/AltSystem42/dragonwilds-dedicated-server-docker)
![GitHub Issues](https://img.shields.io/github/issues/AltSystem42/dragonwilds-dedicated-server-docker)
![License](https://img.shields.io/github/license/AltSystem42/dragonwilds-dedicated-server-docker)
![Docker Build](https://github.com/AltSystem42/dragonwilds-dedicated-server-docker/actions/workflows/docker-build.yml/badge.svg)

A Docker container for running a dedicated RuneScape: Dragonwilds game server with automated updates, scheduled backups, player monitoring, and Discord notifications.

This image installs and runs the official RuneScape: Dragonwilds Dedicated Server (Steam App ID 4019830) using SteamCMD, and keeps it updated automatically.

## What This Actually Installs

This image uses **SteamCMD** to download and install the **official RuneScape: Dragonwilds Dedicated Server** (Steam AppID: `4019830`). The dedicated server is a separate product distributed by Steam — this container simply automates running and maintaining it.

The image includes:
- Ubuntu 24.04 base with 32-bit compatibility libraries
- SteamCMD for server installation and updates
- Entry point script that orchestrates updates, backups, and monitoring

## Prerequisites

- Docker Engine 20.10+ and (optionally) Docker Compose v2
- ~10 GB free disk space for the server install, plus room for backups
- An open UDP port on your host/router for player connections
- No Steam account or login is required — the server installs via SteamCMD anonymous login

## How It Works

When the container starts, the entrypoint script (`scripts/entrypoint-wrapper.sh`) does the following:

1. **Server install/update** — if no server files exist, SteamCMD downloads the Dragonwilds dedicated server; on later starts it checks for updates
2. **Server launch** — starts the dedicated server on the configured UDP port
3. **Player monitoring** — continuously watches the server log for player connections/disconnections
4. **Idle monitoring** — tracks the last player activity to determine when the server is idle

Once the server has been idle for 6+ minutes (configurable), it also runs:

- **Auto-updates** — checks for SteamCMD updates hourly (configurable)
- **Daily backups** — at a configured time, stops the server, backs up SaveGames, and restarts
- **Post-update backups** — after every server update

All backups and updates **skip automatically if players are present**, so gameplay is never interrupted.

Discord webhook alerts can optionally be sent for these events — see `scripts/entrypoint-wrapper.sh` for the implementation details.

## Quick Start

### Post-build setup (required)

After the `server-data` folder has been created (via `docker compose up` or `docker run`), stop the container and edit `server-data/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini`, setting `OwnerId` to the value found under "My Player Id" in the game's settings menu. This grants that player admin privileges.

> ⚠️ **The server will not function until `OwnerId` is set.** This is the single most common setup mistake — don't skip it.

[Official Documentation](https://dragonwilds.runescape.com/news/how-to-dedicated-servers)

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
      - ENABLE_DISCORD_NOTIF=false
      - DISCORD_WEBHOOK_URL=
      - BACKUP_DAILY=true
      - BACKUP_TIME=3:00 AM
      - BACKUP_AFTER_UPDATE=true
      - BACKUP_RETENTION_DAYS=30
      - POLL_INTERVAL=60
      - ENABLE_AUTO_UPDATE=true
      - UPDATE_TIME=3600
      - IDLE_WAIT=360
    volumes:
      - ./server-data:/home/ubuntu/Steam
    restart: unless-stopped
```

### Using a .env File

Create a `.env` file (no quotes needed around values):

```env
SERVER_PORT=7777
ENABLE_DISCORD_NOTIF=true
DISCORD_WEBHOOK_URL=
TZ=America/New_York
BACKUP_DAILY=true
BACKUP_TIME=3:00 AM
BACKUP_AFTER_UPDATE=true
BACKUP_RETENTION_DAYS=30
POLL_INTERVAL=60
ENABLE_AUTO_UPDATE=true
UPDATE_TIME=3600
IDLE_WAIT=360
```

Then reference it from `docker-compose.yml`:

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
| `POLL_INTERVAL` | 60 | Seconds between each player monitoring log check |
| `IDLE_WAIT` | 360 | Seconds to wait for no players before update/backup (default: 6 min) |
| `ENABLE_DISCORD_NOTIF` | false | Enable Discord webhook notifications |
| `DISCORD_WEBHOOK_URL` | (empty) | Discord webhook URL |

## Volume Mounts

| Path | Description |
|------|-------------|
| `/home/ubuntu/Steam` | Server files, saves, and backups |

## Accessing Server Files

- **Saves**: `/home/ubuntu/Steam/RSDragonwilds/Saved/SaveGames`
- **Config**: `/home/ubuntu/Steam/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini`
- **Logs**: `/home/ubuntu/Steam/RSDragonwilds/Saved/Logs/`
- **Backups**: `/home/ubuntu/Steam/backup/`

## Logs

Container logs:
```bash
docker logs dragonwilds
```

Entrypoint script logs (inside the container):
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
  -e TZ=America/New_York \
  -v ./server-data:/home/ubuntu/Steam \
  andyaltsys/dragonwilds-dedicated-server:latest
```

## Troubleshooting

**Container exits immediately after starting**
Check `docker logs dragonwilds` for a SteamCMD install error — this is usually a disk space or permissions issue on the mounted volume.

**Can't connect to the server**
Confirm the UDP port is actually forwarded/open on your router or firewall, not just published in Docker — UDP ports are often missed in NAT/firewall rules that only forward TCP.

**Server starts but I have no admin access**
Double-check `OwnerId` in `DedicatedServer.ini` matches your in-game "My Player Id" exactly, and restart the container after editing it.

**Updates or backups never seem to run**
They only run once the server has been idle for `IDLE_WAIT` seconds (default 360) — if players are connected, both are skipped by design.

## Contributing

Bug reports and pull requests are welcome — please open an [issue](https://github.com/AltSystem42/dragonwilds-dedicated-server-docker/issues) with your container logs if you're reporting a problem.

## Changelog

See [Releases](https://github.com/AltSystem42/dragonwilds-dedicated-server-docker/releases) for version history and changes.

## License

MIT License - See LICENSE file for details.
