# homelab

Self-hosted infrastructure on a repurposed HP EliteBook 850 G6
(CachyOS, 16GB RAM, Intel UHD 620, btrfs).

Runs DNS filtering, recursive resolution, media, service monitoring, and
a log aggregation pipeline. Everything is in Docker, everything is
version controlled, and the failures are documented alongside the
configuration.

## Why this repo exists

Most of the value here is in [NOTES.md](NOTES.md), not the compose
files. Standing up containers is easy. Working out why the network
breaks in a way the vendor documentation does not describe is not.

Three examples of what is written up there:

**A router firmware bug, isolated by controlled testing.** Devices were
intermittently losing IPv4 gateway connectivity while IPv6 kept working.
The cause was an ARP handling bug in the Bell Giga Hub, triggered by
putting a local IP in the router's DNS field. It was misdiagnosed
several times before six consistent data points isolated it. The
permanent fix was architectural: router DHCP off, Pi-hole serving DHCP
and advertising itself as DNS via DHCP options, with the router pointed
only at external resolvers.

**A monitoring script that reported success while collecting nothing.**
Privileged commands under a systemd timer fail silently because there is
no TTY for sudo to prompt on. The service still exited 0, because bash
reports the status of the last command and curl had successfully sent a
notification full of blank fields. It was also generating pam_faillock
entries against my own account on every scheduled run, polluting the
auth logs the Loki pipeline watches for failed SSH.

**SMART reporting differently through a USB bridge.** The internal SATA
SSD and the USB-attached 8TB return different status strings and require
different smartctl device types. One parser cannot cover both, and
getting it wrong returns empty rather than erroring.

## Services

| Service | Purpose | Port |
|---|---|---|
| Pi-hole | Network-wide DNS filtering + DHCP | 53, 67, 80, 443 |
| Unbound | Recursive DNS resolver, DNSSEC | 5335 (localhost) |
| Jellyfin | Media server, VAAPI hardware transcoding | 8096 |
| Uptime Kuma | Service monitoring, 5 monitors | 3001 |
| Grafana | Dashboards and alerting | 3000 |
| Loki | Log aggregation | 3100 (localhost) |
| Grafana Alloy | Log shipping | 12345 (localhost) |

All services run with `network_mode: host`. See NOTES.md for why, and
for the interaction with Pi-hole serving DHCP.

## Network and access

Reachable over LAN and Tailscale. UFW defaults to deny inbound, with
services scoped explicitly to `192.168.2.0/24` and Tailscale's
`100.64.0.0/10` rather than opened broadly. Unbound, Loki, and Alloy
bind to localhost only, since nothing off-host needs to reach them.
UPnP disabled.

Full firewall table and the NordVPN/Tailscale address space collision
are in NOTES.md.

## Detection and monitoring

Grafana Alloy ships system logs into Loki. Failed SSH authentication
detection is confirmed working end to end, from log line to query.
Uptime Kuma covers service availability, including an HTTP health
endpoint check against Jellyfin.

A monthly systemd timer reports battery wear, root and btrfs usage,
media volume usage, CPU and SSD temperatures, SMART status for both
drives, running container count, and failed systemd units, with
threshold alerts pushed to ntfy.

Every collected field is guarded so an empty value reports
`UNKNOWN - check script` rather than a blank line. Blank looks like
formatting. UNKNOWN looks like a problem.

## Backups

Nightly systemd timer archives configuration and captures fstab,
firewall rules, network profiles, container list, and block device
layout. Jellyfin is stopped briefly so its SQLite database is quiesced,
with a trap ensuring the container restarts even if the archive step
fails. Archives older than 60 days are pruned.

Derived data is excluded deliberately: anything that regenerates is
dropped, anything holding state that would have to be recreated by hand
is kept. Jellyfin's Intro Skipper cache alone was 80MB of regenerable
data. Cutting it and similar files took the archive from 117MB to 29MB,
with every database and compose file verified still present.

Known limitation: Pi-hole and Uptime Kuma stay running during the
archive, so their SQLite write-ahead logs are captured mid-flight and
those two databases are not guaranteed to restore cleanly. Documented
rather than silently accepted. The fix is to extend the stop/start trap
to cover all three containers.

## Structure

Each service has its own directory with a `docker-compose.yml`. Runtime
data, secrets, and generated artifacts are gitignored; this repo tracks
configuration, not application state. Services needing credentials ship
a `.env.example` template.

## Setup notes

Scripts calling privileged commands from a systemd timer need a scoped
sudoers drop-in. Blanket NOPASSWD is not required and not used:

    bz ALL=(root) NOPASSWD: /usr/bin/btrfs, /usr/bin/smartctl, /usr/bin/docker
