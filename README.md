# homelab

Self-hosted services running on a repurposed HP EliteBook 850 G6
(CachyOS, 16GB RAM, Intel UHD 620).

## Services

| Service | Purpose | Port |
|---|---|---|
| Pi-hole | Network-wide DNS filtering + DHCP | 53, 67, 80 |
| Unbound | Recursive DNS resolver | 5335 (local) |
| Jellyfin | Media server, QuickSync transcoding | 8096 |
| Uptime Kuma | Service monitoring | 3001 |

All services run in Docker. Pi-hole and Uptime Kuma use host
networking; see NOTES.md for why.

## Structure

Each service has its own directory with a `docker-compose.yml`.
Runtime data directories are gitignored — this repo tracks
configuration, not application state.

## Notes

See [NOTES.md](NOTES.md) for network layout, troubleshooting
history, and known hardware quirks.

## Access

Server reachable over LAN and Tailscale. SSH is scoped to both
ranges; see NOTES.md for the firewall table.
