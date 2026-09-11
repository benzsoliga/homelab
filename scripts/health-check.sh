#!/bin/bash
set -uo pipefail
source /home/bz/homelab/backup.env
TOPIC="$NTFY_TOPIC"

# Battery health
BAT_NOW=$(cat /sys/class/power_supply/BAT0/charge_full)
BAT_DES=$(cat /sys/class/power_supply/BAT0/charge_full_design)
BAT_PCT=$(( BAT_NOW * 100 / BAT_DES ))

# Storage
DISK=$(df -h / | awk 'NR==2 {print $5" used, "$4" free"}')
MEDIA=$(df -h /home/bz/media 2>/dev/null | awk 'NR==2 {print $5" used, "$4" free"}')
BTRFS=$(sudo btrfs filesystem usage / 2>/dev/null | grep "Free (estimated)" | awk '{print $3" free"}')

# Temperatures
TEMP_NUM=$(sensors | grep "Package id 0" | grep -oP '\+\K[0-9]+' | head -1)
SSD_TEMP=$(sudo smartctl -A /dev/sda 2>/dev/null | grep -i "Temperature_Celsius" | awk '{print $10}')
WIFI_TEMP=$(sensors | grep -A2 "iwlwifi" | grep "temp1" | grep -oP '\+\K[0-9]+' | head -1)

# Drive health
SSD_HEALTH=$(sudo smartctl -H /dev/sda 2>/dev/null | grep -i "overall-health" | awk '{print $NF}')
EXT_DEV=$(readlink -f /dev/disk/by-label/media 2>/dev/null | sed 's/[0-9]*$//')
EXT_HEALTH=$(sudo smartctl -d scsi -H "$EXT_DEV" 2>/dev/null | grep "SMART Health Status" | awk '{print $NF}')

# Docker
CONTAINERS=$(sudo docker ps -q 2>/dev/null | wc -l)
FAILED=$(systemctl --failed --no-legend | wc -l)

UP=$(uptime -p)

# Guard empty fields so a silent collection failure is visible
[ -z "$EXT_DEV" ] && EXT_HEALTH="DRIVE NOT FOUND"
[ -z "$EXT_HEALTH" ] && EXT_HEALTH="UNKNOWN - check script"
[ -z "$SSD_HEALTH" ] && SSD_HEALTH="UNKNOWN - check script"
[ -z "$BTRFS" ] && BTRFS="UNKNOWN - check script"

curl -s -H "Title: bz-srv-a monthly check" -d \
"Battery: ${BAT_PCT}% health
Root: ${DISK}
btrfs: ${BTRFS}
Media (8TB): ${MEDIA}
SSD health: ${SSD_HEALTH} (${SSD_TEMP}°C)
Ext drive: ${EXT_HEALTH}
CPU: ${TEMP_NUM}°C | WiFi: ${WIFI_TEMP}°C
Containers running: ${CONTAINERS}
Failed units: ${FAILED}
${UP}" "https://ntfy.sh/${TOPIC}"

# Threshold alerts
if [[ "$TEMP_NUM" =~ ^[0-9]+$ ]] && [ "$TEMP_NUM" -gt 85 ]; then
  curl -s -H "Title: bz-srv-a HIGH CPU TEMP" -H "Priority: high" -H "Tags: warning" \
    -d "CPU at ${TEMP_NUM}°C - check fan and vents" "https://ntfy.sh/${TOPIC}"
fi

if [[ "$SSD_TEMP" =~ ^[0-9]+$ ]] && [ "$SSD_TEMP" -gt 65 ]; then
  curl -s -H "Title: bz-srv-a HIGH SSD TEMP" -H "Priority: high" -H "Tags: warning" \
    -d "SSD at ${SSD_TEMP}°C - throttling likely" "https://ntfy.sh/${TOPIC}"
fi

if [ "$FAILED" -gt 0 ]; then
  curl -s -H "Title: bz-srv-a FAILED UNITS" -H "Priority: high" -H "Tags: warning" \
    -d "$(systemctl --failed --no-legend)" "https://ntfy.sh/${TOPIC}"
fi
