#!/bin/bash
source /home/bz/homelab/backup.env
TOPIC="$NTFY_TOPIC"
THRESHOLD=70

PCT=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')

[ "$PCT" -lt "$THRESHOLD" ] && exit 0

HUMAN=$(df -h / | awk 'NR==2 {print $3" used of "$2", "$4" free"}')
UNALLOC=$(sudo btrfs filesystem usage / | awk '/Device unallocated/ {print $3}')

if [ "$PCT" -ge 85 ]; then
  PRIORITY="urgent"
  NOTE="btrfs may start throwing ENOSPC. Move media off now."
else
  PRIORITY="default"
  NOTE="Plan the move to external storage."
fi

curl -s -H "Title: bz-srv-a disk at ${PCT}%" -H "Priority: ${PRIORITY}" -d \
"${HUMAN}
Unallocated: ${UNALLOC}
${NOTE}" "https://ntfy.sh/${TOPIC}"
