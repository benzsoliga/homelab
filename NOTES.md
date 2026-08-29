# Homelab Notes — bz-srv-a

Last updated: 2026-08-28

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

## Wifi vs ethernet

Both `wlan0` and `enp0s31f6` are configured with the same static IP,
`192.168.2.5`. That means the server keeps its address whichever
interface is active, and the dashboard is always at the same URL.

**But only one can be up at a time.** NetworkManager won't assign a
duplicate address, so if ethernet is connected, wifi will associate but
get no IPv4. Bring one down before bringing the other up.

Currently running on **wifi** (chosen 2026-08-28 to free the cable for
the PC). Latency is ~4ms vs ~0.5ms wired, which doesn't matter for DNS.

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

Router + Internet together tell you whether a problem is yours or Bell's.
The Router monitor is the one that would have caught the DNS-field bug
immediately.

**Blind spot:** Uptime Kuma runs on the machine it monitors. If
`bz-srv-a` dies, nothing reports it. Fine for catching software and
network faults, useless for hardware failure. Adding notifications
(email/Telegram/ntfy) would partly cover this.

## Firewall

ufw is active with default `INPUT DROP`.

| Port | Scope | For |
|---|---|---|
| 22 | Anywhere | SSH |
| 80/tcp | Anywhere | Pi-hole dashboard |
| 53 tcp+udp | `192.168.2.0/24` | DNS |
| 67/udp, 68/udp | Anywhere | DHCP |
| 3001 | `192.168.2.0/24` | Uptime Kuma |

Port 67 matters. Under bridge networking Docker wrote its own iptables
rules and bypassed ufw entirely. Under host networking it doesn't, so
DHCP needs an explicit rule.

The `172.17.0.0/16` and `172.18.0.0/16` rules on port 53 were added
while debugging Uptime Kuma and are no longer needed — host networking
was the actual fix. Safe to remove if they're still present.

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

## This machine is now load-bearing

If `bz-srv-a` is off, **no device on the network can get an IP address**.
Not degraded — offline. Reboot it deliberately, not casually.

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

## Lesson from the build

Hours went into ARP tables, roaming BSSIDs, Docker bridge routes, and
stale lease theories — all wrong. What actually cracked it was plugging
in an ethernet cable and removing an entire layer from the problem.

When something fails in a complicated way, eliminate a layer before
adding another theory.
