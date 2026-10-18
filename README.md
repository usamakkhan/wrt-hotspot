# WrtHotspot

A MikroTik-Hotspot-class captive portal for OpenWrt 24.10+, with full IPv6 support, RADIUS (incl. CoA),
vouchers, per-user shaping, a LuCI app and a standalone operator panel.

Status: **Phases 1–6 working**, tested end to end on OpenWrt 25.12.5 x86-64 against FreeRADIUS 3.2.10,
with rates measured by iperf3 (137 + 48 end-to-end checks).

- [docs/research.md](docs/research.md) — stack, prior art, dataplane and MikroTik feature research
- [docs/architecture.md](docs/architecture.md) — architecture, phases and MikroTik parity matrix

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
- MikroTik-compatible page templates (`$(var)`, `$(if)…$(elif)…$(else)…$(endif)`) and servlet pages.
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

`luci-app-wrt-hotspot` adds **Services → Hotspot** with ten pages: Status (live sessions with logout,
hosts with their IPv4/IPv6 addresses, cookies), Users (add/edit/reset/delete local users), Servers and
server profiles, User Profiles, Limitations, Walled Garden, IP Bindings, RADIUS, Settings, and
Diagnostics (health checks with one-click fixes, hotspot network setup, log everybody out).
Configuration changes apply through LuCI's normal Save & Apply; hotspotd reloads in place without
dropping sessions.

Optional packages: `wrt-hotspot-shaper` (tc HTB shaping), `dnsmasq-full` (walled-garden subdomains),
`libustream-mbedtls` (HTTPS login).

Measured on the test VM (iperf3 through the hotspot, steady state): `1M/4M` → 3.88 / 3.77 Mbit/s down
(IPv4 / IPv6) and 0.94 Mbit/s up; a 512k limitation → 0.52 Mbit/s; nftables policing at 4M → 3.98 Mbit/s;
`1M/1M 4M/4M 768k/768k 8/8` → ~3.1 Mbit/s in the first second, then ~1 Mbit/s; unlimited → 8+ Gbit/s.
TCP goodput through HTB is about 95% of the configured rate (TCP/IP + Ethernet headers); short tests read
lower because of TCP's ramp-up.

Note on IPv6 IP bindings: a binding by single IPv6 address only matches that address, and devices
change addresses (SLAAC, privacy extensions). Bind IPv6 devices by MAC.

## Layout

```
feed/net/wrt-hotspot/           OpenWrt package (add feed/ as a src-link feed)
feed/luci/luci-app-wrt-hotspot/ LuCI app (views in htdocs/, menu + ACL in root/)
feed/net/wrt-hotspot-panel/     operator panel (www/hotspot/) + rpcd ACL for staff roles
  files/usr/sbin/hotspotd       daemon (ucode, uloop, ubus object "wrthotspot")
  files/usr/sbin/wrthotspot     CLI
  files/usr/share/ucode/wrthotspot/   modules: core, nft, hosts, users, config, api, dns, radius, shaper, limits, diag,
                                vouchers, records, operators, template, util
  files/usr/share/wrthotspot/   portal.uc (uhttpd handler) and default pages
tests/unit/                     ucode unit tests        (sh tests/run-unit.sh)
tests/integration/              end-to-end netns test   (sh tests/integration/netns-test.sh)
```

## Try it on a router (24.10+)

```sh
apk add ucode-mod-digest ucode-mod-rtnl ucode-mod-uloop uhttpd uhttpd-mod-ucode   # opkg on 24.10
sh tests/integration/install-dev.sh
wrthotspot setup <network>          # e.g. a dedicated "hotspot" interface
service firewall reload && service wrthotspot restart
wrthotspot user add alice password=secret
```

The end-to-end test builds its own throwaway topology (network namespaces + a test bridge). Run it only on
a dedicated test device: it needs `ip-full`, `kmod-veth` and `curl`.
