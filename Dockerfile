# Base image
FROM ubuntu:24.04

# Default UID/GID for ubuntu user
ARG UID=1000
ARG GID=1000

# Install dependencies including tzdata
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        lib32gcc-s1 \
        lib32stdc++6 \
        curl \
        wget \
        unzip \
        ca-certificates \
        sudo \
        jq \
        tzdata \
        gosu \
    && rm -rf /var/lib/apt/lists/*

# Adjust existing ubuntu user/group
RUN groupmod -g $GID ubuntu && usermod -u $UID -g $GID ubuntu

# Install SteamCMD
RUN mkdir -p /home/ubuntu/steamcmd && \
    cd /home/ubuntu/steamcmd && \
    wget https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz && \
    tar --no-same-owner -xvzf steamcmd_linux.tar.gz && \
    rm steamcmd_linux.tar.gz && \
    chmod +x steamcmd.sh linux32/steamcmd

# Create server folder
RUN mkdir -p /home/ubuntu/Steam

# Fix ownership
RUN chown -R ubuntu:ubuntu /home/ubuntu

# Environment variables
ENV HOME=/home/ubuntu
ENV STEAMCMDDIR=/home/ubuntu/steamcmd
ENV SERVERDIR=/home/ubuntu/Steam
ENV SERVER_PORT=7777

# Auto-update settings
ENV ENABLE_AUTO_UPDATE=true
ENV UPDATE_TIME=3600

# Backup settings
ENV BACKUP_DAILY=true
ENV BACKUP_TIME="3:00 AM"
ENV BACKUP_AFTER_UPDATE=true
ENV BACKUP_RETENTION_DAYS=30
ENV POLL_INTERVAL=60

# Server idle settings
ENV IDLE_WAIT=360

# Discord notifications
ENV ENABLE_DISCORD_NOTIF=false
ENV DISCORD_WEBHOOK_URL=""

# Timezone (can be overridden via .env)
ENV TZ=UTC

# Copy wrapper script only
COPY scripts/entrypoint-wrapper.sh /home/ubuntu/entrypoint-wrapper.sh
RUN chmod +x /home/ubuntu/entrypoint-wrapper.sh

# Configure timezone at build time default; runtime TZ env var is respected
# by glibc automatically — no symlink needed at runtime
RUN ln -snf /usr/share/zoneinfo/UTC /etc/localtime && echo UTC > /etc/timezone

WORKDIR /home/ubuntu

# Container starts as root so the entrypoint can fix volume ownership,
# then drops to the ubuntu user via gosu
ENTRYPOINT ["/home/ubuntu/entrypoint-wrapper.sh"]