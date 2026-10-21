# WrtHotspot

A captive portal hotspot for OpenWrt 24.10+, inspired by MikroTik Hotspot, with full IPv6 support, RADIUS (incl. CoA),
vouchers, per-user shaping, a LuCI app and a standalone operator panel.

Status: **0.8.1 — Phases 1–8 working, qualified on x86**: tested end to end on OpenWrt 25.12.5 x86-64
against FreeRADIUS 3.2.10 (154 + 53 + 16 + 34 + 24 + 12 end-to-end checks), rates measured by iperf3, 2000 sessions on one 236 MB VM and
150 simultaneous real clients through the portal, upgrades from 0.7.0 through the signed feed. Packages
build with the official 24.10 (ipk) and 25.12 (apk) SDKs. The unit tests and the end-to-end suites also run on
emulated MIPS (big-endian, 128 MB) and ARM routers in QEMU (`tests/emu/`); physical routers are still to be tested.

- Source: [github.com/usamakkhan/wrt-hotspot](https://github.com/usamakkhan/wrt-hotspot) ([releases](https://github.com/usamakkhan/wrt-hotspot/releases), [issues](https://github.com/usamakkhan/wrt-hotspot/issues))
- [docs/research.md](docs/research.md) — stack, prior art, dataplane and feature research
- [docs/architecture.md](docs/architecture.md) — architecture, phases and feature comparison
- [docs/qualification.md](docs/qualification.md) — load and traffic tests, capacity tiers
- [docs/billing-integration.md](docs/billing-integration.md) — SAS4 and other RADIUS / billing systems, RouterOS API
- [CHANGELOG.md](CHANGELOG.md) — what changed in each release

## What works today

- Dual-stack dataplane in its own nftables table (`inet wrthotspot`); clients are identified by MAC,
  so every IPv6 address of a device (incl. SLAAC privacy addresses) is online after one login.
- Unauthenticated clients: HTTP (v4 + v6) redirected to the portal, DNS hijacked to the router,
  everything else rejected.
- Logins: HTTP-PAP, HTTP-CHAP, HTTPS, MAC, trial, HTTP cookie and MAC cookie (MikroTik semantics: cookies
  survive idle/keepalive timeouts, are dropped on logout, admin reset and limits).
- Local users with limit-uptime and limit-bytes-in/out/total, shared-users, server and MAC locks.
- Session/idle/keepalive timeouts, per-session byte/packet accounting, MikroTik terminate causes.
- Walled garden by host (incl. subdomains), address/prefix, protocol and port, with deny exceptions;
  host entries are filled by dnsmasq `nftset=` and by hotspotd's own resolver (works on stock dnsmasq too).
- IP bindings: bypassed / blocked by MAC, address/prefix or MAC+address, globally or per server.
  Blocked hosts can't even reach the portal or DNS.
- OS captive-portal probes (Apple, Android, Windows, Firefox) handled before and after login.
- RFC 8908 API at `/api/captive`; RFC 8910 URI announced in DHCPv4 option 114 (dnsmasq) and via
  odhcpd's `captive_portal_uri` (RA/DHCPv6 on odhcpd 2026+).
- Portal name (`dns_name`) answered by dnsmasq with the router's IPv4 *and* IPv6 address per interface.
- MikroTik-compatible page templates (`$(var)`, `$(if)…$(elif)…$(else)…$(endif)`) and servlet pages;
  custom login pages uploaded as a zip in LuCI (see [Custom login pages](#custom-login-pages)).
- Survives daemon restart, `fw4 reload`, and even deletion of its table (rebuilt within one poll).
- RADIUS (RFC 2865/2866/2869/5176): PAP, CHAP and MAC authentication; Message-Authenticator on every
  request and required in replies (BlastRADIUS hardening); server failover with retries; accounting
  Start/Interim/Stop with gigawords, Class echo, IPv4 + IPv6 Framed addresses and terminate causes;
  undeliverable accounting is queued and retried; CoA and Disconnect-Request listener (ACK/NAK,
  Error-Cause). Applied attributes: Session-Timeout, Idle-Timeout, Acct-Interim-Interval, Port-Limit,
  Reply-Message, Class, Mikrotik-Group, Mikrotik-Rate-Limit, Mikrotik-Recv/Xmit/Total-Limit (+gigawords),
  WISPr-Bandwidth-Max-Up/Down, WISPr-Session-Terminate-Time / -End-Of-Day. Cookie logins of RADIUS
  users replay the stored authorization instead of keeping passwords.
- Per-user rate limits in MikroTik syntax (`rx/tx`, burst rate/threshold/time, priority, limit-at) from
  user profiles, scheduled limitations, RADIUS (`Mikrotik-Rate-Limit`, WISPr bandwidth) and CoA, changed
  live. With `wrt-hotspot-shaper` installed: HTB + fq_codel per user and direction, classified by MAC
  (IPv4 and IPv6 alike), uploads via IFB, MikroTik burst semantics (average over burst-time vs threshold,
  evaluated every poll). Without it: nftables policing (rate only).
- Scheduled limitations (User Manager style): weekday + time windows (overnight too), a rate limit per
  window, and download/upload/transfer/uptime quotas per hourly/daily/weekly/monthly period. Logins outside
  every window are refused and sessions end when the window closes.
- `wrthotspot` CLI: `setup <network>` wizard (zone, rules, DHCP/RA, offload off, server), `cert`, `cookies`, …
- Capacity tiers: from its RAM, flash and conntrack table the router knows how many sessions and user
  accounts it can carry while keeping a free-memory buffer (modes safe / balanced / max); a 64 MB
  router gets about 55 / 170 / 260 sessions, never fewer than 10. Logins beyond the limit are
  refused ("the hotspot is full") unless `capacity_override` is set; adding users beyond it needs an
  admin to confirm a warning. Manual `max_sessions` / `max_users` override the computed values.
- Lite mode for slow routers (`option lite`, automatic up to 64 MB of RAM): one process per login
  and logout instead of up to four. Rate limits use nftables policing (no burst, priority or fair
  queuing), the last check interval of traffic before a logout is not counted, and connections of
  logged-out clients expire on their own instead of being flushed.
- Third-party RADIUS / billing: presets for MikroTik-style servers (SAS4, Radius Manager, Splynx,
  User Manager, daloRADIUS) and CoovaChilli-style ones (RADIUSdesk, HotspotSystem); ChilliSpot and
  Ascend attributes; a RouterOS API subset on tcp/8728 so billing systems can list and disconnect
  online users and manage hotspot users. See [docs/billing-integration.md](docs/billing-integration.md).
- RADIUS is optional (`wrt-hotspot-radius`): small routers run on local users and vouchers only.
- Transparent HTTP proxy per server profile (MikroTik `transparent-proxy` / `http-proxy`): a proxy on
  the router (IPv4 + IPv6) or another host. Traffic through a proxy *on the router* is not counted
  toward users' data limits or accounting (it never crosses the forward path); with a proxy on
  another host it is.

## Operator panel

`wrt-hotspot-panel` serves a staff panel at `http://<router>/hotspot/` (no external libraries, works
offline, phone-friendly): a dashboard (online now, today's sessions, traffic, vouchers sold, revenue,
7-day charts), voucher batches (profile, count, prefix, code length and alphabet without look-alikes,
PIN or code + password, validity from first use, online-time/data limits, price), printable voucher
sheets (cards, tickets or list, with your title and note) and CSV export, user management (edit,
extend, reset, delete), who is online (with logout), session history with search and CSV, and
reports grouped by day, hour, user, batch, profile, server or login method.

Staff log in with their own accounts, created with `wrthotspot operator add <user> operator|admin`
or by an admin in the panel. They are rpcd logins with salted MD5-crypt passwords, confined by rpcd
ACLs: operators get users, vouchers, sessions, history and reports, admins additionally manage
operators, and neither can touch the router's configuration. Batches record which operator made
them. Voucher codes log in on the portal with the code alone.

## LuCI app

`luci-app-wrt-hotspot` adds **Services → Hotspot** with eleven pages: Status (live sessions with logout,
hosts with their IPv4/IPv6 addresses, cookies), Users (add/edit/reset/delete local users), Servers and
server profiles, User Profiles, Limitations, Walled Garden, IP Bindings, Login Pages (upload and download
page sets), RADIUS, Settings, and Diagnostics (health checks with one-click fixes, hotspot network setup,
log everybody out).
Configuration changes apply through LuCI's normal Save & Apply; hotspotd reloads in place without
dropping sessions.

Optional packages: `wrt-hotspot-radius` (RADIUS, billing), `wrt-hotspot-shaper` (tc HTB shaping), `dnsmasq-full` (walled-garden subdomains),
`libustream-mbedtls` (HTTPS login).

Measured on the test VM (iperf3 through the hotspot, steady state): `1M/4M` → 3.88 / 3.77 Mbit/s down
(IPv4 / IPv6) and 0.94 Mbit/s up; a 512k limitation → 0.52 Mbit/s; nftables policing at 4M → 3.98 Mbit/s;
`1M/1M 4M/4M 768k/768k 8/8` → ~3.1 Mbit/s in the first second, then ~1 Mbit/s; unlimited → 8+ Gbit/s.
TCP goodput through HTB is about 95% of the configured rate (TCP/IP + Ethernet headers); short tests read
lower because of TCP's ramp-up.

Note on IPv6 IP bindings: a binding by single IPv6 address only matches that address, and devices
change addresses (SLAAC, privacy extensions). Bind IPv6 devices by MAC.

## Custom login pages

The pages hotspot users see come from a *page set*: a folder with `login.html` and, optionally,
`alogin.html`, `status.html`, `logout.html`, `flogout.html`, `fstatus.html`, CSS, images and scripts.
Two sets are built in: `default` (minimal) and `classic` (full-screen layout in the style of RouterOS's
stock hotspot page, OpenWrt logo, three colour themes).

To make your own, open **Services → Hotspot → Login Pages** in LuCI:

1. **Download sample** gets the `classic` set as a zip, with a README listing every page variable.
   Any other set can be downloaded the same way.
2. Edit the pages, replace `img/logo.svg`, zip the folder.
3. **Upload** the zip under a name of your choice. The browser unpacks it (stock OpenWrt has no
   `unzip`); the router checks every file and installs the set only when the whole upload is good.
4. **Use** picks the set for a server profile (or choose it under Servers → *Login pages*).

Rules: `login.html` at the top of the zip or inside one folder; file types html, css, js, png, jpg,
gif, svg, ico, webp, woff/woff2, json and txt (others are left out and reported); at most 512 KiB per
file, 2 MiB and 200 files per set; enough free flash. Uploaded sets live in `/etc/wrthotspot/pages/`
and survive a sysupgrade. A page missing from a set falls back to the built-in default page.

MikroTik hotspot page sets work as they are: zip the RouterOS `hotspot` folder and upload it.
Variables use the MikroTik syntax (`$(var)`, `$(if var == 'x')…$(endif)`), values are HTML-escaped
(`$(var-raw)` opts out), and the stock trial link (`username=T-$(mac-esc)`) starts a trial. RouterOS
files WrtHotspot does not use (`errors.txt`, `rlogin.html`, `radvert.html`, `xml/`) are kept but ignored.

## Layout

```
feed/net/wrt-hotspot/           OpenWrt package (add feed/ as a src-link feed)
feed/luci/luci-app-wrt-hotspot/ LuCI app (views in htdocs/, menu + ACL in root/)
feed/net/wrt-hotspot-panel/     operator panel (www/hotspot/) + rpcd ACL for staff roles
  files/usr/sbin/hotspotd       daemon (ucode, uloop, ubus object "wrthotspot")
  files/usr/sbin/wrthotspot     CLI
  files/usr/share/ucode/wrthotspot/   modules: core, nft, hosts, users, config, api, dns, radius, shaper, limits, diag,
                                vouchers, records, operators, pages, template, util
  files/usr/share/wrthotspot/   portal.uc (uhttpd handler) and the built-in page sets (default, classic)
scripts/build-packages.sh       builds all packages with the official SDK of a release
tests/unit/                     ucode unit tests        (sh tests/run-unit.sh)
tests/integration/              end-to-end netns test   (sh tests/integration/netns-test.sh),
                                panel API test, 2000-session load test, real-traffic test
tests/emu/                      OpenWrt on emulated MIPS/ARM in QEMU: install from the feed, run the suites
```

## Build the packages

On a Linux host with the [SDK prerequisites](https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem):

```sh
git clone https://github.com/usamakkhan/wrt-hotspot.git && cd wrt-hotspot
scripts/build-packages.sh 24.10.8     # -> dist/24.10.8/: *.ipk + Packages (usign-signed) + public key
scripts/build-packages.sh 25.12.6     # -> dist/25.12.6/: *.apk + packages.adb (signed) + wrthotspot.pem
```

Each `dist/<release>/` is a complete signed package feed. The signing keys are created on the first
build in `~/.wrthotspot-keys` (or `$WRTHOTSPOT_KEYS`): keep them, every later release must be signed
with the same keys. The packages are architecture independent, so one feed serves every target of a
release. CI (`.github/workflows/ci.yml`) runs the unit tests in the OpenWrt rootfs images and builds
both sets.

| Package | Contents |
|---|---|
| `wrt-hotspot` | daemon, portal, CLI, local users and vouchers |
| `wrt-hotspot-radius` | RADIUS, CoA, billing presets, RouterOS API (needs the same core version) |
| `wrt-hotspot-shaper` | pulls in tc / HTB / IFB for real shaping |
| `wrt-hotspot-panel` | operator panel at `/hotspot/` |
| `luci-app-wrt-hotspot` | LuCI pages (translation template in `po/templates`, `scripts/i18n-scan.py`) |
| `wrt-hotspot-full` | all of the above |

### Install from the feed

The feeds are published as assets of the GitHub releases
([releases](https://github.com/usamakkhan/wrt-hotspot/releases)). The `latest` URL always serves the
newest release, so routers set up this way get every update with `apk upgrade` / `opkg upgrade`:

```sh
# 25.12 (apk)
wget -O /etc/apk/keys/wrthotspot.pem https://github.com/usamakkhan/wrt-hotspot/releases/latest/download/wrthotspot.pem
echo https://github.com/usamakkhan/wrt-hotspot/releases/latest/download/packages.adb >> /etc/apk/repositories.d/customfeeds.list
apk update && apk add wrt-hotspot-full

# 24.10 (opkg)
wget -O /tmp/wrthotspot.pub https://github.com/usamakkhan/wrt-hotspot/releases/latest/download/dcedbf2d84a0ef59
opkg-key add /tmp/wrthotspot.pub
echo 'src/gz wrthotspot https://github.com/usamakkhan/wrt-hotspot/releases/latest/download' >> /etc/opkg/customfeeds.conf
opkg update && opkg install wrt-hotspot-full
```

To stay on one version instead, use `releases/download/v0.8.1/` in place of `releases/latest/download/`.

**Publishing a release:** build both feeds (`scripts/build-packages.sh`), create the release with every
file of `dist/24.10.8/` and `dist/25.12.6/` except `index.json`, and mark it Latest. Then also upload
the new packages and index files (`Packages*`, `packages.adb`) with `--clobber` to the older releases
(from v0.8.0 on): routers that were set up with a versioned URL then see the update too.

Release downloads only work without a login while the repository is public; for a private
repository, serve the `dist/<release>/` directory from your own web server instead and use its URL.

Upgrades then come with `apk upgrade` / `opkg upgrade`. Packages that were installed from files
(0.7.0 and earlier) are pinned to those files: add them once by name from the feed
(`apk add wrt-hotspot wrt-hotspot-shaper wrt-hotspot-panel luci-app-wrt-hotspot`), then
`apk upgrade`. Since 0.8.0 RADIUS is a separate package: add `wrt-hotspot-radius` if you use it.
Sessions, users and configuration survive the upgrade (`tests/integration/upgrade-test.sh`).

## Try it on a router (24.10+)

```sh
cd /tmp/25.12.6 && apk add --allow-untrusted ./*.apk     # 25.12 (unsigned local packages)
cd /tmp/24.10.8 && opkg install ./*.ipk                   # 24.10
# from a source checkout instead (dependencies from feed/net/wrt-hotspot/Makefile first):
#   sh tests/integration/install-dev.sh
wrthotspot setup <network>          # e.g. a dedicated "hotspot" interface
service firewall reload && service wrthotspot restart
wrthotspot user add alice password=secret
```

The end-to-end test builds its own throwaway topology (network namespaces + a test bridge). Run it only on
a dedicated test device: it needs `ip-full`, `kmod-veth` and `curl`.

## License and trademarks

GPL-2.0-or-later (see the package Makefiles). WrtHotspot is an independent project inspired by
MikroTik Hotspot; it is not affiliated with or endorsed by MikroTik. MikroTik and RouterOS are
trademarks of their owner. Names such as `Mikrotik-Rate-Limit` or "RouterOS API" are used only to
describe compatibility with existing RADIUS servers, billing systems and page templates.
