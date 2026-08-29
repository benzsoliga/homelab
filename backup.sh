#!/bin/bash
set -e
source "$(dirname "$0")/backup.env"
STAMP=$(date +%Y%m%d-%H%M)
DEST=/home/bz/backups/homelab-$STAMP
mkdir -p "$DEST"

cp /etc/systemd/logind.conf "$DEST/"
ufw status verbose > "$DEST/ufw-rules.txt"
nmcli connection show > "$DEST/nmcli-connections.txt"
nmcli connection show "$WIFI_SSID" > "$DEST/nmcli-wifi-profile.txt"
nmcli connection show "Wired connection 1" > "$DEST/nmcli-wired-profile.txt"
docker ps -a > "$DEST/docker-containers.txt"

tar czf /home/bz/backups/homelab-$STAMP.tar.gz -C /home/bz/backups homelab-$STAMP
rm -rf "$DEST"
chown bz:bz /home/bz/backups/homelab-$STAMP.tar.gz
find /home/bz/backups -name "homelab-*.tar.gz" -mtime +60 -delete
echo "Backup: /home/bz/backups/homelab-$STAMP.tar.gz"
