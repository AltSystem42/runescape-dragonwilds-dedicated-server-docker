# Dragonwilds Dedicated Server

![Docker Pulls](https://img.shields.io/docker/pulls/andyaltsys/dragonwilds-dedicated-server)
![License](https://img.shields.io/github/license/AltSystem42/runescape-dragonwilds-dedicated-server-docker)

A Docker container for running a RuneScape: Dragonwilds dedicated game server.

This image uses SteamCMD to download and install the official dedicated server binaries (Steam AppID: 4019830), keeping them automatically updated.

## Features

- **Auto-updates** — Checks for new server builds every hour by default (`UPDATE_TIME`) and only runs SteamCMD when the local build differs from Steam's
- **Idle-aware maintenance** — Updates and backups wait until no player has been online for `IDLE_WAIT` seconds, then stop and restart the game process *inside the same container* — the container never exits mid-update
- **Daily backups** — Scheduled at a configurable time (`BACKUP_TIME`), catching up if the container was down at that moment, and pruned after `BACKUP_RETENTION_DAYS`
- **Post-update backups** — Automatic backup after each server update
- **Player monitoring** — Tails the game log for join/leave events, tracking the online player count and last activity
- **Discord notifications** — Alerts for installs, updates, backups, and player events
- **Server settings via env** — Configure owner ID, server name, world name, and passwords with environment variables or `.env`; an empty value keeps whatever is already in `DedicatedServer.ini`
- **Config preservation** — `DedicatedServer.ini` is backed up before each update and restored afterwards
- **Bind-mount friendly** — Starts as root, matches its `ubuntu` user to your volume's UID/GID, then drops privileges with `gosu` — no manual `chown` needed
- **Separate script logs** — Entrypoint logs go to their own persistent, size-rotated log file (`logs/entrypoint.log`)
- **Crash handling** — If the game process exits unexpectedly, the container exits too, so your `restart:` policy brings it back

## Quick Start

```bash
docker run -d \
  --name dragonwilds \
  -p 7777:7777/udp \
  -e SERVER_PORT=7777 \
  -e OWNER_ID=your-in-game-player-id \
  -e SERVER_NAME="My Dragonwilds Server" \
  -e TZ=America/New_York \
  -e BACKUP_DAILY=true \
  -e BACKUP_TIME="3:00 AM" \
  -e BACKUP_AFTER_UPDATE=true \
  -e BACKUP_RETENTION_DAYS=30 \
  -e ENABLE_AUTO_UPDATE=true \
  -e UPDATE_TIME=3600 \
  -e IDLE_WAIT=360 \
  -e POLL_INTERVAL=60 \
  -e ENABLE_DISCORD_NOTIF=false \
  -v ./server-data:/home/ubuntu/Steam \
  --restart unless-stopped \
  andyaltsys/dragonwilds-dedicated-server:latest
```

Or use the included `docker-compose.yml` — it reads all of its configuration from a `.env` file, so create one first with `cp .env.example .env`.

> **First run:** set `OWNER_ID` to your in-game Player ID — shown at the bottom of the game's Settings menu (use the copy button). It is mandatory: the official docs say the server will not start without it, and the player it identifies becomes the server's owner.

Server files, saves, config, and backups live under `./server-data` on the host (mounted at `/home/ubuntu/Steam` in the container).

## Configuration

For full configuration options (server settings, updates, backups, Discord, logging), examples, and troubleshooting, see the [GitHub README](https://github.com/AltSystem42/runescape-dragonwilds-dedicated-server-docker).

## Version History

| Tag | Description |
|-----|-------------|
| `latest` | Most recent release |
| `v0.4.0` | Major release — server reliably restarts after auto-update/backup; server settings via `.env` (OWNER_ID, SERVER_NAME, etc.); separate rotated script log; `.env` no longer tracked (use `.env.example`) |
| `v0.3.5` | Fix update subshell killed before steamcmd |
| `v0.3.4` | Fix update notification firing every hour |
| `v0.3.3` | Fix chown crossing into bind-mounted volume |
| `v0.3.2` | Fix perms, add first-run install, fix tz |
| `v0.3.1` | Fix auto-update loop firing every hour |
| `v0.3.0` | fix backup loop spam and update interval |
| `v0.2.8` | Add backup catch-up for missed scheduled backups |
| `v0.2.7` | add IDLE_WAIT as configurable env variable |
| `v0.2.6` | add idle wait for updates and unified logic |
| `v0.2.5` | fix player detection and backup scheduling |
| `v0.2.4` | fix daily backup scheduling |
| `v0.2.3` | fix daily backup scheduling |
| `v0.2.2` | Bug fixes |
| `v0.2.1` | Bug fixes and improvements |
| `v0.2.0` | Feature enhancements and optimizations |
| `v0.1.0` | Initial release — auto-updates, backups, player monitoring, Discord notifications |

## Support

Report issues at: https://github.com/AltSystem42/runescape-dragonwilds-dedicated-server-docker/issues
