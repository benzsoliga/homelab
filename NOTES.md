# Homelab Notes — bz-srv-a

Last updated: 2026-08-30

## The big one: never put a local IP in the router's DNS field

**Router:** Sagemcom Fast 5697 (Bell Giga Hub), gateway `192.168.2.1`

This router has a bug. Any local IP address entered into
*Advanced tools and settings → DNS → Manually specify DNS information*
gets **cut off from the gateway**. That device can still be reached by
other machines on the LAN, and IPv6 to the router keeps working, but it
can no longer talk to `192.168.2.1` over IPv4.

Worse: switching the radio button back to "Obtain DNS information
automatically" does **not** undo it. The stored value stays active.
You have to actually clear the field and save a non-local address.

**Confirmed six times** on 2026-08-27/28: `.20` and `.5` both died while
in that field, `.60`, `.6` and `.7` worked fine while absent from it.
Clearing the field restored `.5` immediately.

Currently set to Primary `1.1.1.1`, Secondary `9.9.9.9`. **Leave it that way.**

### Symptoms if this happens again

- `ping 192.168.2.1` → `Destination Host Unreachable`
- `ip neigh show` → gateway stuck at `INCOMPLETE`, other hosts `REACHABLE`
- `arping -I <iface> 192.168.2.1` → 0 responses
- IPv6 ping to the router's link-local address works fine
- Other devices can ping the affected machine without trouble

### Diagnostic that actually works

Test with a different source IP on the same interface:

```bash
sudo ip addr add 192.168.2.99/24 dev enp0s31f6
sudo arping -I enp0s31f6 -s 192.168.2.99 -c 4 192.168.2.1
sudo ip addr del 192.168.2.99/24 dev enp0s31f6
```

If a fresh IP gets replies and the current one doesn't, it's this bug.

Other people hit this and misdiagnosed it as MAC filtering or as "low IP
addresses are blocked". Both are wrong. The variable is the DNS field.

## Network layout

| Item | Value |
|---|---|
| Server | `bz-srv-a`, CachyOS |
| Address | `192.168.2.5/24` static — **both** profiles set to this |
| Active interface | `wlan0` (wifi) as of 2026-08-28 |
| Fallback | `enp0s31f6` (ethernet), also configured for `.5` |
| Gateway | `192.168.2.1` |
| DHCP range | `192.168.2.10` – `192.168.2.254`, served by Pi-hole |
| Router DHCP | **OFF** — must stay off |
| Tailscale | `100.122.58.9` |

Ethernet MAC: <redacted>
Wifi MAC: <redacted>

The router has **no DHCP reservation feature**. Only a read-only lease
table with a "Clear all" button. That's why the server uses a static IP
below the DHCP pool start of `.10`.

**Reboot test passed 2026-08-29.** Static IP survives a restart on wifi.
Pi-hole, Unbound, and Uptime Kuma all come back on their own.

## Wifi vs ethernet

Both `wlan0` and `enp0s31f6` are configured with the same static IP,
`192.168.2.5`. That means the server keeps its address whichever
interface is active, and the dashboard is always at the same URL.

**But only one can be up at a time.** NetworkManager won't assign a
duplicate address, so if ethernet is connected, wifi will associate but
get no IPv4. Bring one down before bringing the other up.

Currently running on **wifi** (chosen 2026-08-28 to free the cable for
the PC). Latency is ~4ms vs ~0.5ms wired, which doesn't matter for DNS.
It *would* matter for large Samba transfers — plug in if moving a lot
of media.

### If the network misbehaves, plug the cable in first

This is the fastest diagnostic available. Ethernet removes the entire
wireless layer from the problem in one move. It's what cracked the
original build after hours of wrong theories.

```bash
sudo nmcli connection down "<WIFI-SSID>"
sudo nmcli connection up "Wired connection 1"
ping -c 3 192.168.2.1
```

To go back to wifi:

```bash
sudo nmcli connection down "Wired connection 1"
sudo nmcli connection up "<WIFI-SSID>"
ping -c 3 192.168.2.1
```

If `nmcli connection up` fails with a confusing "device not available /
mismatching interface name" error right after `nmcli radio wifi on`,
the radio just hadn't finished initializing. Wait a few seconds and
retry, or name the device explicitly with `ifname wlan0`.

## Pi-hole

Dashboard: http://192.168.2.5/admin
Compose file: `~/homelab/pihole/docker-compose.yml`
Backup of the old bridge-network version: `docker-compose.yml.bak`

Runs with `network_mode: host` and `cap_add: NET_ADMIN`. Host networking
is **required** for DHCP — broadcast traffic does not cross a Docker
bridge. It also means the query log shows real client IPs instead of
lumping everything under `172.18.0.1`.

Pi-hole serves both DNS and DHCP for the whole network. This is the
workaround for the router bug above: instead of telling the router to
point clients at Pi-hole (which would poison Pi-hole's own IP), Pi-hole
tells clients directly via DHCP.

### If DHCP settings won't tick in the web UI

There's a padlock icon on the settings panel. Click it to unlock.
Or set it from the command line:

```bash
sudo docker exec pihole pihole-FTL --config dhcp.active
sudo docker exec pihole pihole-FTL --config dhcp.start 192.168.2.10
sudo docker exec pihole pihole-FTL --config dhcp.end 192.168.2.254
sudo docker exec pihole pihole-FTL --config dhcp.router 192.168.2.1
sudo docker exec pihole pihole-FTL --config dhcp.active true
```

Verify it's actually listening:

```bash
sudo ss -ulnp | grep :67
```

### Listening mode resets on container recreate

Default mode refuses queries from outside the container's own subnet.
Must be "Permit all origins" — Settings → DNS in the dashboard, or:

```bash
docker exec pihole pihole-FTL --config dns.listeningMode
```

Anything set through the dashboard that isn't also in the compose file
vanishes on the next recreate. Same category as the password env
conflict that had to be removed from `docker-compose.yml` so
`pihole setpassword` would work.

## Unbound

Config: `~/homelab/unbound/conf/unbound.conf` (tracked in git)
Compose file: `~/homelab/unbound/docker-compose.yml`

Recursive resolver on `127.0.0.1:5335`, `network_mode: host`, DNSSEC
validation via `root.key`. Pi-hole's only upstream, so DNS queries
resolve from the root servers instead of going to Cloudflare or Quad9.

`access-control` is loopback-only and `interface` is `127.0.0.1`. That
is deliberate — nothing outside the host should reach it directly.

### CONNECTION_ERROR (127.0.0.1#5335) in Pi-hole's diagnosis page

**Cosmetic.** It's an idle TCP timeout between Pi-hole and Unbound, not
a fault. Confirm with:

```bash
sudo docker logs unbound          # empty = healthy
sudo ss -lnp | grep 5335          # both UDP and TCP sockets present
```

### Runtime state that must stay out of git

`unbound/conf/` holds both config and state. `unbound.conf` is tracked;
`root.key`, `unbound.pid`, `var/`, and `dev/` are gitignored. The
`dev/` directory contains root-owned device nodes (`random`, `urandom`,
`null`) created by the container — these also broke `cp -a` in the
backup script until that copy was removed.

## Jellyfin

Dashboard: http://192.168.2.5:8096
Compose file: `~/homelab/jellyfin/docker-compose.yml`

Mounts:

| Host | Container |
|---|---|
| `/home/bz/homelab/jellyfin/config` | `/config` |
| `/home/bz/homelab/jellyfin/cache` | `/cache` |
| `/home/bz/media` | `/media` |

Runs as uid/gid 1000 — same as `bz`, which owns `/home/bz/media`. This
is why Samba's `force user = bz` matters.

`/media` is the mount point chosen deliberately so the external 8TB
can be mounted there later without changing any Docker config.

## Samba

Config: `/etc/samba/smb.conf` — **outside `~/homelab`, not in git yet**
Share: `[media]` → `/home/bz/media`, mapped as `Z:` on the PC
Port: 445/tcp, scoped to `192.168.2.0/24`

`force user = bz` and `force group = bz` guarantee files land owned by
uid 1000, which is what Jellyfin runs as. Without that, transfers
succeed and Jellyfin sees an empty folder.

`disable netbios = yes` means the server will **not** appear in Windows'
Network browse view. Expected — use the mapped drive, not browsing.

Samba keeps its own password database, separate from the Linux one:

```bash
sudo smbpasswd -a bz
```

Windows caches credentials per server. If the Samba password changes,
clear the old one in Credential Manager or the mapping fails silently
with a permissions error.

### Map network drives from a normal PowerShell window, not elevated

Windows treats an elevated session as a separate logon. Mappings made
in an admin shell are **invisible to Explorer**, which runs
non-elevated. Symptom: `net use` shows the drive as OK from the admin
window, `net use Z: /delete` from a normal window says "connection
could not be found", and the drive never appears in This PC.

```powershell
net use Z: \\192.168.2.5\media /user:bz /persistent:yes
```

Unaffected by NordVPN — SMB is handled in the Windows kernel and does
not go through the VPN's app-level split tunnelling.

## Snapshots (btrfs + snapper)

Installed 2026-08-29: `snapper`, `snap-pac`, `btrfs-assistant`.

Retention in `/etc/snapper/configs/root`:

```
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="2"
TIMELINE_LIMIT_MONTHLY="0"
TIMELINE_LIMIT_YEARLY="0"
```

`snap-pac` snapshots automatically before and after every pacman
transaction. Snapshot 6 is tagged `important=yes` — the fresh-install
baseline, exempt from cleanup.

Everyday commands:

```bash
sudo snapper -c root list
sudo snapper -c root status 18..0        # what changed since snapshot 18
sudo snapper -c root undochange 19..0 /etc/some-file   # revert one path
sudo btrfs filesystem usage /            # real usage; df lies on btrfs
```

`undochange` is surgical. `snapper rollback <N>` swaps the whole root
subvolume and needs a reboot — that's the "it won't boot" tool.

**Rollback tested 2026-08-29** and confirmed working.

### Docker moved to its own subvolume

`/var/lib/docker` was inside `@`, so every root snapshot pinned Pi-hole's
database, Jellyfin's cache, and every image layer. Moved out:

```bash
sudo systemctl stop docker docker.socket
sudo mv /var/lib/docker /var/lib/docker.old
sudo btrfs subvolume create /var/lib/docker
sudo cp -a --reflink=auto /var/lib/docker.old/. /var/lib/docker/
sudo systemctl start docker
```

`--reflink=auto` shares blocks instead of duplicating, so the copy is
near-instant and doesn't need double the space.

**`@home` is not snapshotted.** `~/homelab` and `~/media` have no
snapshot coverage — git is the only version control for the configs,
which is an argument for committing often.

### Btrfs disk headroom

`df` undercounts on btrfs because it doesn't account for
snapshot-pinned blocks. Use `btrfs filesystem usage /`. The number that
matters is **Device unallocated** — when that hits zero while data
chunks are full, btrfs throws `ENOSPC` even though `df` claims free
space.

Thresholds on the 949.9 GiB root:

| Mark | Size |
|---|---|
| 60% — comfortable ceiling | 570 GiB |
| 70% — start planning | 665 GiB |
| 85% — btrfs starts misbehaving | 807 GiB |

**Do not fill the internal drive with media.** `/config`, `/cache`, and
transcode scratch all live on the same filesystem, and a 4K transcode
can write tens of GB. Media goes on the external drive when it arrives.

## Firewall

ufw is active with default `INPUT DROP`. Everything is scoped except
DHCP, which can't be.

| Port | Scope | For |
|---|---|---|
| 22 | `192.168.2.0/24` + `100.64.0.0/10` | SSH |
| 53 tcp+udp | `192.168.2.0/24` | DNS |
| 67/udp, 68/udp | Anywhere (v4 + v6) | DHCP |
| 80/tcp | `192.168.2.0/24` + `100.64.0.0/10` | Pi-hole dashboard |
| 445/tcp | `192.168.2.0/24` | Samba |
| 3001 | `192.168.2.0/24` + `100.64.0.0/10` | Uptime Kuma |
| 8096 | `192.168.2.0/24` + `100.64.0.0/10` | Jellyfin |

**DHCP stays open to Anywhere deliberately.** Clients requesting an
address don't have one yet, so a subnet-scoped rule can block them.

Port 67 matters. Under bridge networking Docker wrote its own iptables
rules and bypassed ufw entirely. Under host networking it doesn't, so
DHCP needs an explicit rule.

### IPv6 twins are easy to miss

Closing a v4 rule alone leaves the door open on the other protocol. The
v6 SSH and port 80 rules were deleted separately on 2026-08-29/30.

**ufw's delete confirmation drops the `(v6)` marker** — both rules print
as `allow 22`. Read `ufw status numbered` immediately before *and*
after each delete; numbers shift every time one is removed. Delete
highest-first.

### Rules survive reboots; sessions don't get re-checked

ufw evaluates on connection *establishment*. An open SSH session stays
alive after you delete the rule that allowed it — which is why tightening
rules over SSH is safe, and why testing must use a **fresh** connection.

Physical console is always the escape hatch: `sudo ufw disable`.

## Router port forwarding

**UPnP disabled 2026-08-30.** An application had auto-opened seven
forwarding rules via UPnP without prompting. Nothing was compromised —
that is simply how UPnP works — but any program on any device could
punch a hole to the internet unannounced, and none of those rules were
serving any purpose.

Cost of disabling: consoles and some P2P games get strict NAT. Manual
forwarding still available for anything genuinely needed.

Current manual rules (all on MSI-Benz, the Windows PC):

| Rule | Port | State |
|---|---|---|
| Game Port | 9876 udp | OFF unless hosting |
| Steam Query Port | 9877 udp | ON |
| RCON | 25575 tcp | OFF — keep it off |

**Never forward anything to `192.168.2.5`.** That machine runs DNS and
DHCP for the whole house and must never be reachable from the internet.

**RCON stays off.** It is remote console access to a game server — full
command execution if the password is weak.

**Check this page monthly.** Anything unexplained gets deleted. Port
forwarding is the one path that genuinely reaches past the router;
automated scanners find open ports within hours.

## Backups and health checks

### Config backup

`~/homelab/backup.sh`, run nightly at 03:00 by
`homelab-backup.timer`. Needs root (`ufw status verbose`).

Captures the things git does **not** cover: `logind.conf`, ufw rules,
nmcli profiles, container list. Writes a timestamped tarball to
`~/backups/` and prunes anything older than 60 days.

The SSID comes from `~/homelab/backup.env`, which is gitignored.
`backup.env.example` documents the shape. Before this was fixed the
script had a literal `<Wifi-SSID>` placeholder and `set -e` killed it
silently — **backups had not been running.**

**Known weakness: the backup writes to the same disk it protects.**
Same blind-spot class as Uptime Kuma monitoring its own host. Real fix
arrives with the external drive.

**Second weakness:** when the script fails mid-run, `set -e` exits
before the `rm -rf "$DEST"` cleanup, leaving temp directories behind.
A `trap 'rm -rf "$DEST"' EXIT` near the top would fix it.

### Health check

`~/homelab/scripts/health-check.sh`, fired monthly by
`health-check.timer` (`Persistent=true`, so a missed run fires on next
boot). Pushes battery health, disk usage, CPU temp, and uptime to ntfy.

Battery baseline: `charge_full=3258000`, 67% health, 139 cycles.

Charge thresholds **cannot** be set via sysfs on this EliteBook — no
`charge_control_end_threshold` exposed. It's a BIOS setting: F10 at
boot → Battery Health Manager.

## Git repo

`~/homelab` → `git@github.com:benzsoliga/homelab.git` (private)

SSH key `~/.ssh/id_ed25519` on the server, registered under GitHub
account settings. Verify with `ssh -T git@github.com`.

Everyday flow:

```bash
cd ~/homelab
git add .
git commit -m "what changed"
git push
```

### What stays out

`.gitignore` separates configuration from runtime state. Tracked:
compose files, `unbound.conf`, scripts, notes. Ignored: Pi-hole's
gravity database and dnsmasq dir, Jellyfin config and cache, Uptime
Kuma data, Unbound's `root.key`/`var/`/`dev/`/`*.pid`, `*.env`,
`*.key`, `*.pem`, `*.bak`.

**Before making this public**, scrub identifying details. MACs and the
wifi SSID are already redacted — a MAC plus an SSID is enough to locate
a household via WiGLE. Git keeps history, so anything committed and
pushed stays readable even after a later edit. Scrub *before* commit,
or `git commit --amend` if nothing has been pushed yet.

## Sleep is disabled

`/etc/systemd/logind.conf`:

```
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
```

Plus all sleep targets masked:

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

Reverse with `unmask` if this machine ever goes back to being a laptop.

**Keep the vents clear** — it runs with the lid closed.

## Uptime Kuma

Dashboard: http://192.168.2.5:3001
Compose file: `~/homelab/uptime-kuma/docker-compose.yml`

Also runs `network_mode: host`. Started on the default bridge with
`ports: 3001:3001`, but the DNS monitor pointed at `192.168.2.5:53`
failed from there — a bridged container can't reliably hairpin back to
the host's LAN address. Opening ufw to `172.17.0.0/16` and
`172.18.0.0/16` did **not** fix it; host networking did.

General rule that emerged: Docker's bridge is fine for containers that
only make outbound web requests. Anything that needs to be a real
participant on the LAN — serving DHCP, monitoring other hosts — wants
host networking.

Monitors configured:

| Name | Type | Target |
|---|---|---|
| Router | Ping | `192.168.2.1` |
| Internet | Ping | `1.1.1.1` |
| Pi-hole DNS | DNS | `google.com` via resolver `192.168.2.5` |
| Pi-hole Web | HTTP(s) | `http://192.168.2.5/admin` |
| Jellyfin | HTTP(s) | health endpoint |

Router + Internet together tell you whether a problem is yours or Bell's.
The Router monitor is the one that would have caught the DNS-field bug
immediately.

**No Unbound monitor, deliberately.** A monitor pointed at
`127.0.0.1:5335` returns `ETIMEOUT` even though `dig` from the host
works — Uptime Kuma's loopback isn't the host's loopback. Making it
work would mean binding Unbound to `192.168.2.5` and opening
`access-control` to the LAN, widening the resolver's surface for no
functional gain. Unbound is Pi-hole's only upstream, so if it dies the
Pi-hole DNS monitor goes red within a minute anyway.

**Blind spot:** Uptime Kuma runs on the machine it monitors. If
`bz-srv-a` dies, nothing reports it. Fine for software and network
faults, useless for hardware failure. ntfy notifications partly cover
this — a push that stops arriving is itself a signal.

## This machine is now load-bearing

If `bz-srv-a` is off, **no device on the network can get an IP address**.
Not degraded — offline. Reboot it deliberately, not casually.

Run pacman updates while physically near the laptop. A kernel update
can break a network driver, and then the box comes up with no network
at all. The physical console and `snap-pac`'s pre-transaction snapshot
are the two things that make that a five-minute rollback instead of an
ordeal.

## Things to watch

- **Router DHCP toggle self-reverting.** Reported by others on the Bell
  forums. If the network starts behaving strangely, check that the
  router's DHCP is still off before anything else. Two DHCP servers
  competing produces confusing intermittent failures.
- **Firefox DNS-over-HTTPS.** On by default in Canada. It bypasses
  Pi-hole entirely. Settings → Privacy & Security → DNS over HTTPS → Off.
  Updates sometimes re-enable it.
- **Tailscale hijacking DNS.** After a container restart or interface
  change, `nslookup` may show `Server: 100.100.100.100` instead of
  `127.0.0.1`. It still resolves through Pi-hole but adds a hop. Fixed
  with `sudo tailscale set --accept-dns=false`. Check this if DNS starts
  behaving oddly after a restart.
- **Ads that survive.** YouTube, Amazon, and Wikipedia's own fundraising
  banners are served from the same domain as the content, so DNS
  blocking cannot touch them. Keep uBlock Origin installed alongside.
- **`btrfs-assistant` segfaults over SSH.** It needs a display. Run it
  at the physical XFCE session, or just use the CLI.
- **Fish doesn't do heredocs.** Any `<< 'EOF'` block has to be wrapped
  in `bash -c '...'` or typed into nano instead.

## VPN client failure modes (2026-08-29)

Three separate NordVPN behaviours broke things that looked like server
faults. Every one of them cost time debugging the wrong machine.

- **The kill switch blocks LAN traffic**, not just internet. Local
  access stops even when the target is one room away. Nord's own text
  says "Stay invisible on LAN" is the setting that stops local traffic —
  but the Internet Kill Switch does it too, as a side effect.
- **Tunnel adapters persist DNS after disconnect.** NordLynx showed
  "Media disconnected" while an OpenVPN adapter was live at `10.100.0.2`
  holding DNS priority with Nord's resolvers. "The VPN is off" is not
  the same as "no tunnel adapter is up."
- **Nord and Tailscale do not coexist here.** With Nord connected,
  Tailscale drops to `DERP(tor)` relay and the local node goes offline.
  Split tunnelling with `tailscaled.exe` on the bypass list gave one
  successful direct ping and then dropped again. **LAN SSH was reopened
  as the workaround** — rules 11 and 12 both allow port 22.

Also worth knowing: Nord's split tunnelling has an inverted mode. "Use
VPN for selected apps" means everything *else* bypasses the tunnel — the
opposite of what you usually want. Check the dropdown, not just the app
list.

### Reflex when the network breaks after touching the VPN

```powershell
ipconfig /all                                    # live tunnel adapters?
Get-DnsClientServerAddress -AddressFamily IPv4   # who holds DNS?
Test-NetConnection 192.168.2.5 -Port 445         # is the path clear?
```

Check the client before the server. Three of the four "server problems"
on 2026-08-29 were the Windows box.

## Lessons from the build

Hours went into ARP tables, roaming BSSIDs, Docker bridge routes, and
stale lease theories — all wrong. What actually cracked it was plugging
in an ethernet cable and removing an entire layer from the problem.

**When something fails in a complicated way, eliminate a layer before
adding another theory.**

The Nord debugging on 2026-08-29 failed the same way and for the same
reason: theories kept getting added instead of closing Nord and testing
clean. The lesson was already written down. Writing it down isn't the
same as reaching for it.

**Untested is unproven.** The backup script had been silently failing
for days. The firewall rule wasn't confirmed until a *fresh* SSH attempt
timed out. The static IP wasn't confirmed until the machine actually
rebooted. In every case the config looked right.

**Things get opened for a reason; the reason expires, the opening
doesn't.** The port 80 ufw rule, the `testing` forward on 12000-12001,
seven stale UPnP entries serving nothing. None of these were attacks.
All of them were forgotten decisions.
