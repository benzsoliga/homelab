#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/backup.env"
STAMP=$(date +%Y%m%d-%H%M)
DEST=/home/bz/backups/homelab-$STAMP
ARCHIVE=/home/bz/backups/homelab-$STAMP.tar.gz
mkdir -p "$DEST"

cp /etc/systemd/logind.conf "$DEST/"
cp /etc/fstab "$DEST/"
ufw status verbose > "$DEST/ufw-rules.txt"
nmcli connection show > "$DEST/nmcli-connections.txt"
nmcli connection show "$WIFI_SSID" > "$DEST/nmcli-wifi-profile.txt"
nmcli connection show "Wired connection 1" > "$DEST/nmcli-wired-profile.txt"
docker ps -a > "$DEST/docker-containers.txt"
lsblk -f > "$DEST/lsblk.txt"

trap 'docker start jellyfin >/dev/null 2>&1 || true' EXIT
docker stop jellyfin >/dev/null 2>&1 || true
tar czf "$ARCHIVE" \
  --exclude=homelab/jellyfin/config/metadata \
  --exclude=homelab/jellyfin/config/log \
  --exclude=homelab/jellyfin/cache \
  --exclude=homelab/jellyfin/config/data/introskipper \
  --exclude=homelab/jellyfin/config/data/subtitles \
  --exclude=homelab/jellyfin/config/data/splashscreen.png \
  --exclude=homelab/pihole/etc-pihole/gravity_old.db \
  --exclude=homelab/pihole/etc-pihole/listsCache \
  --exclude=backups \
  -C /home/bz homelab \
  -C /home/bz/backups "homelab-$STAMP"
docker start jellyfin >/dev/null 2>&1 || true

rm -rf "$DEST"
chown bz:bz "$ARCHIVE"
find /home/bz/backups -name "homelab-*.tar.gz" -mtime +60 -delete
echo "Backup: $ARCHIVE"
