#!/bin/bash
source /home/bz/homelab/backup.env
TOPIC="$NTFY_TOPIC"
BAT_NOW=$(cat /sys/class/power_supply/BAT0/charge_full)
BAT_DES=$(cat /sys/class/power_supply/BAT0/charge_full_design)
BAT_PCT=$(( BAT_NOW * 100 / BAT_DES ))
DISK=$(df -h / | awk 'NR==2 {print $5" used, "$4" free"}')
TEMP=$(sensors | awk '/Package id 0/ {print $4}')
UP=$(uptime -p)
DRIVE=$(sudo smartctl -d scsi -H /dev/sdb 2>/dev/null | grep "SMART Health Status" | awk '{print $NF}')
MEDIA=$(df -h /home/bz/media | awk 'NR==2 {print $5" used, "$4" free"}')

curl -s -H "Title: bz-srv-a monthly check" -d \
"Battery: ${BAT_PCT}% health
Disk: ${DISK}
Media (8TB): ${MEDIA}
Drive health: ${DRIVE}
Temp: ${TEMP}
${UP}" "https://ntfy.sh/${TOPIC}"
