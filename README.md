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

1. **Privilege drop** — if running as root, it matches the `ubuntu` user's UID/GID to the mounted volume's owner, chowns only its own internal directories (never the bind-mounted volume), and re-executes itself as `ubuntu` via `gosu` — so no manual `chown` on the host is needed
2. **Server install (first run only)** — if the server binary is missing, SteamCMD downloads the Dragonwilds dedicated server (up to 5 attempts, `validate`). Later starts do **not** re-verify files: the update loop below compares the local and remote Steam `buildid` every `UPDATE_TIME` seconds and runs SteamCMD only when they differ
3. **Config sync** — applies your server settings (`OWNER_ID`, `SERVER_NAME`, `DEFAULT_WORLD_NAME`, `ADMIN_PASSWORD`, `WORLD_PASSWORD`, `SERVER_GUID`) to `DedicatedServer.ini` from environment variables / `.env` (empty values keep whatever is already in the ini)
4. **Server launch** — starts the dedicated server on the configured UDP port
5. **Player monitoring** — tails the game log every 5 seconds for join/leave events, tracking the online-player count and last-activity timestamp in files under the mounted volume (so idle state survives container restarts)
6. **Update & backup loops** — background loops check for updates (via SteamCMD) and run the daily backup on schedule
7. **Supervision loop** — the wrapper waits on the game process: if it was stopped for maintenance it restarts it in place; if it crashed or exited on its own, the container exits so your `restart:` policy can bring it back

Updates and backups are **idle-aware**: they wait until no players are online and the server has been idle for `IDLE_WAIT` seconds (default 360 = 6 minutes). The update path blocks and logs its reason every 60 seconds; the backup loop retries every `POLL_INTERVAL`. For maintenance the wrapper stops the server, runs SteamCMD or the backup — before an update it copies `DedicatedServer.ini` to `backup/` and restores it afterwards — and then **restarts the server in the same container** — so maintenance never exits the container or kills the process mid-update. If an operation never finishes, the wrapper forces a restart after 1 hour instead of hanging forever.

If the container was down when a daily backup was scheduled, the backup runs on the next start once the scheduled time has passed (and the server is idle).

Discord webhook notifications can optionally be sent for installs, updates, backups, and player join/leave events (`ENABLE_DISCORD_NOTIF` / `DISCORD_WEBHOOK_URL`).

## Quick Start

### Post-build setup: set `OwnerId` (required)

`OwnerId` identifies your player as the server's owner — the only one who can ban/unban — and the [official docs](https://dragonwilds.runescape.com/news/how-to-dedicated-servers) state the server will not start without it. This is the single most common setup mistake. Set it **one** of two ways:

**Option A — via `.env` (recommended):** add your in-game "My Player Id" (at the bottom of the game's Settings menu — use the copy button) to `.env`:

```env
OWNER_ID=your-in-game-player-id
```

The container writes it into `DedicatedServer.ini` automatically on every start.

**Option B — edit the ini:** after the `server-data` folder has been created (via `docker compose up` or `docker run`), stop the container and edit `server-data/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini`, setting `OwnerId` to the value found under "My Player Id" in the game's settings menu.

> ⚠️ **The server will not start until `OwnerId` is set** (per the official docs). This is the single most common setup mistake — don't skip it.

[Official Documentation](https://dragonwilds.runescape.com/news/how-to-dedicated-servers)

### Docker Run

```bash
docker run -d \
  --name dragonwilds \
  -p 7777:7777/udp \
  -e SERVER_PORT=7777 \
  -e TZ=America/New_York \
  -e BACKUP_TIME="3:00 AM" \
  -e OWNER_ID=your-in-game-player-id \
  -v ./server-data:/home/ubuntu/Steam \
  andyaltsys/dragonwilds-dedicated-server:latest
```

> `OWNER_ID` is **required** — it must be your in-game "My Player Id" (see [Post-build setup](#post-build-setup-set-ownerid-required)).

### Docker Compose

The repo ships a ready-to-use [`docker-compose.yml`](docker-compose.yml):

```yaml
services:
  dragonwilds:
    image: andyaltsys/dragonwilds-dedicated-server:latest
    container_name: dragonwilds
    ports:
      - "${SERVER_PORT}:${SERVER_PORT}/udp"
    env_file:
      - .env
    volumes:
    - ./server-data:/home/ubuntu/Steam
    restart: unless-stopped
```

It reads **all** of its configuration from `.env` — including `SERVER_PORT`, which is used for the port mapping — so make sure `.env` exists first (create it with `cp .env.example .env` and set `OWNER_ID`; full details below), then start:

```bash
docker compose up -d
```

> `restart: unless-stopped` will bring the container (and server) back after a host reboot. On a normal update/backup the container stays up — only the game process restarts. If the game process exits on its own, the container exits too, and this policy restarts it.

### Using a .env File

Start from the template — copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
# then edit `.env` with your settings
```

Here's a complete `.env` — any variable from the [Environment Variables](#environment-variables) table below can be added too:

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
SERVER_STOP_TIMEOUT=120

# Logging
LOG_TO_STDOUT=true
MAX_LOG_SIZE=5242880
LOG_RETENTION=5

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
| `POLL_INTERVAL` | 60 | Seconds between checks of the daily-backup schedule — also the retry interval while waiting for the server to become idle |
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
| `OWNER_ID` | (empty) | **Required.** Your in-game "My Player Id" (bottom of the game's Settings menu) — makes that player the server owner. The official docs say the server will not start without it; the container logs a warning if it is unset. |
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
  -e OWNER_ID=your-in-game-player-id \
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
  -e OWNER_ID=your-in-game-player-id \
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
  -e OWNER_ID=your-in-game-player-id \
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
They only run once the server has been idle for `IDLE_WAIT` seconds (default 360) with no players online. Nothing is skipped: the update check **blocks** and logs its reason every 60 seconds (`docker exec dragonwilds tail -f /home/ubuntu/Steam/logs/entrypoint.log`), and the daily backup loop **retries every `POLL_INTERVAL`** seconds until it can proceed. If players stay online for a long time, that is why nothing has happened yet.

**My `DedicatedServer.ini` edits disappeared**
Two things can overwrite the file: the game itself, if you edit it while the server is running (a known limitation — the official docs warn about it), and the wrapper, which re-applies non-empty environment values on every container start (empty values leave your manual edits alone). Prefer `.env` for settings; if you edit the ini directly, do it while the container is stopped and make sure the matching environment variable is empty.

**The game process crashed**
If the server exits on its own, the wrapper stops the container rather than restarting the game in place (only scheduled maintenance restarts it internally). With `restart: unless-stopped` Docker brings the whole container back automatically.

## Contributing

Bug reports and pull requests are welcome — please open an [issue](https://github.com/AltSystem42/runescape-dragonwilds-dedicated-server-docker/issues) with your container logs if you're reporting a problem.

The Docker Hub repository description is maintained in [`dockerhub.md`](dockerhub.md) and synced automatically by the build workflow (`docker-build.yml`) on every push or tag.

## Changelog

See [Releases](https://github.com/AltSystem42/runescape-dragonwilds-dedicated-server-docker/releases) for version history and changes.

## License

MIT License - See LICENSE file for details.