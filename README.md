# Dragonwilds Dedicated Server Docker Image

![Docker Pulls](https://img.shields.io/docker/pulls/andyaltsys/dragonwilds-dedicated-server)
![GitHub Release](https://img.shields.io/github/v/release/AltSystem42/runescape-dragonwilds-dedicated-server-docker)
![GitHub Issues](https://img.shields.io/github/issues/AltSystem42/runescape-dragonwilds-dedicated-server-docker)
![License](https://img.shields.io/github/license/AltSystem42/runescape-dragonwilds-dedicated-server-docker)
![Docker Build](https://github.com/AltSystem42/runescape-dragonwilds-dedicated-server-docker/actions/workflows/docker-build.yml/badge.svg)

A Docker container for running a dedicated RuneScape: Dragonwilds game server with automated updates, scheduled backups, player monitoring, Discord notifications, and environment-driven server configuration.

This image installs and runs the official RuneScape: Dragonwilds Dedicated Server (Steam App ID 4019830) using SteamCMD, and keeps it updated automatically.

## What This Actually Installs

This image uses **SteamCMD** to download and install the **official RuneScape: Dragonwilds Dedicated Server** (Steam AppID: `4019830`). The dedicated server is a separate product distributed by Steam — this container simply automates running and maintaining it. No Steam account or login is required (anonymous login).

The image includes:
- Ubuntu 24.04 base with 32-bit compatibility libraries
- SteamCMD for server installation and updates
- Entry point script that orchestrates updates, backups, monitoring, and configuration

## Prerequisites

- Docker Engine 20.10+ and (optionally) Docker Compose v2
- ~10 GB free disk space for the server install, plus room for backups
- An open UDP port on your host/router for player connections
- No Steam account or login is required — the server installs via SteamCMD anonymous login

## How It Works

When the container starts, the entrypoint script (`scripts/entrypoint-wrapper.sh`) does the following:

1. **Privilege drop** — if running as root, it matches the container's process UID/GID to the mounted volume's owner, so no manual `chown` on a bind mount is needed
2. **Server install/verify** — if the server binary is missing, SteamCMD downloads the Dragonwilds dedicated server (retrying up to 5 times); on later starts it verifies the files before launching
3. **Config sync** — applies your server settings (`OWNER_ID`, `SERVER_NAME`, `DEFAULT_WORLD_NAME`, `ADMIN_PASSWORD`, `WORLD_PASSWORD`, `SERVER_GUID`) to `DedicatedServer.ini` from environment variables / `.env` (empty values keep whatever is already in the ini)
4. **Server launch** — starts the dedicated server on the configured UDP port
5. **Player monitoring** — watches the game log for join/leave events, tracking the online-player count and last activity
6. **Update & backup loops** — background loops check for updates (via SteamCMD) and run the daily backup on schedule

Updates and backups are **idle-aware**: they wait until no players are online and the server has been idle for `IDLE_WAIT` seconds (default 360 = 6 minutes). During maintenance the wrapper stops the server, runs SteamCMD or the backup, and then **restarts the server in the same container** — so maintenance never exits the container or kills the process mid-update.

Discord webhook notifications can optionally be sent for updates, backups, and player join/leave events (`ENABLE_DISCORD_NOTIF` / `DISCORD_WEBHOOK_URL`).

## Quick Start

### Post-build setup: set `OwnerId` (required)

`OwnerId` grants your player admin privileges on the server. The server will not function (for you) until it is set — this is the single most common setup mistake. Set it **one** of two ways:

**Option A — via `.env` (recommended):** add your in-game "My Player Id" (shown in the game's settings menu) to `.env`:

```env
OWNER_ID=your-in-game-player-id
```

The container writes it into `DedicatedServer.ini` automatically on every start.

**Option B — edit the ini:** after the `server-data` folder has been created (via `docker compose up` or `docker run`), stop the container and edit `server-data/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini`, setting `OwnerId` to the value found under "My Player Id" in the game's settings menu.

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
  -e OWNER_ID= # required — set to your in-game "My Player Id" (see Post-build setup)
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
      - OWNER_ID=  # required — your in-game "My Player Id" (see Post-build setup)
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

> `restart: unless-stopped` will bring the container (and server) back after a host reboot. On a normal update/backup the container stays up — only the game process restarts.

### Using a .env File

Start from the template — copy `.env.example` to `.env` and fill in your values.

```bash
cp .env.example .env
# then edit `.env` with your settings
```

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

# Server settings (written to DedicatedServer.ini on container start)
# OWNER_ID is required — your in-game "My Player Id" (see "Post-build setup")
OWNER_ID=
SERVER_NAME=My Dragonwilds Server
DEFAULT_WORLD_NAME=MyWorld
ADMIN_PASSWORD=change-me
WORLD_PASSWORD=
SERVER_GUID=
```

> Leave any server-setting variable empty to keep whatever value already exists in `DedicatedServer.ini` (e.g. a manual ini edit). Set it to force an override on the next container start.

`.env` is **gitignored**, so passwords and your owner ID stay on your machine — mirror this repo's `.env.example` instead of committing a `.env`.

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
| `SERVER_STOP_TIMEOUT` | 120 | Max seconds to wait for the server to stop cleanly (SIGTERM) before force-killing it (SIGKILL) during updates/backups |
| `BACKUP_AFTER_UPDATE` | true | Backup saves after each update |
| `BACKUP_DAILY` | true | Run daily scheduled backup |
| `BACKUP_TIME` | 3:00 AM | Daily backup time (12-hour format with AM/PM) |
| `BACKUP_RETENTION_DAYS` | 30 | Days to keep backups |
| `POLL_INTERVAL` | 60 | Seconds between checks of the daily-backup schedule |
| `IDLE_WAIT` | 360 | Seconds of no players before an update/backup proceeds (default: 6 min) |
| `ENABLE_DISCORD_NOTIF` | false | Enable Discord webhook notifications |
| `DISCORD_WEBHOOK_URL` | (empty) | Discord webhook URL |
| `LOG_TO_STDOUT` | true | Also echo script log lines to the container stdout (`docker logs`). Set to `false` to keep script messages in the log file only |
| `MAX_LOG_SIZE` | 5242880 (5 MB) | Rotate the script log once it reaches this many bytes |
| `LOG_RETENTION` | 5 | Number of rotated script log generations to keep (`MAX_LOG_SIZE` × `LOG_RETENTION` bounds disk usage) |

### Server Settings (written to `DedicatedServer.ini`)

These are applied to `server-data/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini` on every container start. Set a variable to override the ini value; leave it empty to keep whatever is already in the ini. The generated defaults below only apply when the key is missing entirely (e.g. a fresh install).

| Variable | Default | Description |
|----------|---------|-------------|
| `OWNER_ID` | (empty) | **Required.** Your in-game "My Player Id" from the game's settings menu — grants that player admin. The container logs a warning if it is unset. |
| `SERVER_NAME` | `Server-<timestamp>` | Server name shown in the world browser |
| `DEFAULT_WORLD_NAME` | `World-<timestamp>` | World name used to find the server in the world browser |
| `ADMIN_PASSWORD` | random string | Admin password for the server (only generated once if absent) |
| `WORLD_PASSWORD` | (empty) | Optional password required to join the world |
| `SERVER_GUID` | (empty) | Leave empty unless you know what you're doing |

> Mapped path note: the container writes to `/home/ubuntu/Steam/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini`, which is the same file as `server-data/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini` on your host via the volume mount.

## Volume Mounts

| Path | Description |
|------|-------------|
| `/home/ubuntu/Steam` | Server files, saves, and backups |

## Accessing Server Files

- **Saves**: `/home/ubuntu/Steam/RSDragonwilds/Saved/SaveGames`
- **Config**: `/home/ubuntu/Steam/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini`
- **Game logs**: `/home/ubuntu/Steam/RSDragonwilds/Saved/Logs/`
- **Script log**: `/home/ubuntu/Steam/logs/entrypoint.log` (on host: `./server-data/logs/entrypoint.log`)
- **Backups**: `/home/ubuntu/Steam/backup/`

## Logs

**Container logs** — mixed, includes both script messages (unless `LOG_TO_STDOUT=false`) and the game server's console output:
```bash
docker logs dragonwilds
```

**Script log** — dedicated file for the entrypoint script, separate from the game's logs:
- Inside container: `/home/ubuntu/Steam/logs/entrypoint.log`
- On host: `./server-data/logs/entrypoint.log`

```bash
docker exec dragonwilds tail -f /home/ubuntu/Steam/logs/entrypoint.log
```

The script log is appended across container restarts (so update/backup history survives) and rotated by size — disk usage is bounded by `MAX_LOG_SIZE` × `LOG_RETENTION`. Each entry is prefixed with a timestamp `[YYYY-MM-DD HH:MM:SS]`.

**Game server log** — the running server's own output:
`./server-data/RSDragonwilds/Saved/Logs/RSDragonwilds.log`

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

**Server vanishes from the server browser after an auto-update**
Since v0.4.0 the wrapper stops, updates, and restarts the server within the same container — it should never disappear after maintenance. If the game process still won't come back, check `./server-data/logs/entrypoint.log` for SteamCMD errors.

**My server-settings changes aren't being applied**
Settings are applied from the environment on every container start, but an **empty** value deliberately preserves what's already in `DedicatedServer.ini`. To change a setting, put an actual value in `.env` and restart the container.

**Can't connect to the server**
Confirm the UDP port is actually forwarded/open on your router or firewall, not just published in Docker — UDP ports are often missed in NAT/firewall rules that only forward TCP.

**Server starts but I have no admin access**
Double-check `OwnerId` in `DedicatedServer.ini` (or `OWNER_ID` in `.env`) matches your in-game "My Player Id" exactly, and restart the container after editing it.

**Updates or backups never seem to run**
They only run once the server has been idle for `IDLE_WAIT` seconds (default 360) — if players are connected, both are skipped (and backups retry) by design.

## Contributing

Bug reports and pull requests are welcome — please open an [issue](https://github.com/AltSystem42/runescape-dragonwilds-dedicated-server-docker/issues) with your container logs if you're reporting a problem.

The Docker Hub repository description is maintained in [`dockerhub.md`](dockerhub.md) and synced automatically by the build workflow (`docker-build.yml`) on every push or tag.

## Changelog

See [Releases](https://github.com/AltSystem42/runescape-dragonwilds-dedicated-server-docker/releases) for version history and changes.

## License

MIT License - See LICENSE file for details.