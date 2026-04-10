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
ENV IDLE_WAIT=360
ENV BACKUP_RETENTION_DAYS=30
ENV BACKUP_AFTER_UPDATE=true
ENV BACKUP_DAILY=true
ENV BACKUP_TIME="3:00 AM"

# Discord notifications
ENV ENABLE_DISCORD_NOTIF=false
ENV DISCORD_WEBHOOK_URL=""

# Timezone (can be overridden via .env)
ENV TZ=UTC

# Copy wrapper script only
COPY scripts/entrypoint-wrapper.sh /home/ubuntu/entrypoint-wrapper.sh
RUN chmod +x /home/ubuntu/entrypoint-wrapper.sh

# Switch to non-root user
USER ubuntu
WORKDIR /home/ubuntu

# Configure timezone at runtime
# This ensures TZ from .env works inside the container
ENTRYPOINT ["/bin/bash", "-c", "\
if [ -n \"$TZ\" ]; then \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone; \
fi; \
/home/ubuntu/entrypoint-wrapper.sh \
"]