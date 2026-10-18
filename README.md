# WrtHotspot

A MikroTik-Hotspot-class captive portal for OpenWrt 24.10+, with full IPv6 support, RADIUS (incl. CoA),
vouchers, per-user shaping, a LuCI app and a standalone operator panel.

Status: **Phases 1–2 working**, tested end to end on OpenWrt 25.12.5 x86-64 (85/85 checks).

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
- `wrthotspot` CLI: `setup <network>` wizard (zone, rules, DHCP/RA, offload off, server), `cert`, `cookies`, …

Optional packages: `dnsmasq-full` (walled-garden subdomains), `libustream-mbedtls` (HTTPS login).

Note on IPv6 IP bindings: a binding by single IPv6 address only matches that address, and devices
change addresses (SLAAC, privacy extensions). Bind IPv6 devices by MAC.

## Layout

```
feed/net/wrt-hotspot/           OpenWrt package (add feed/ as a src-link feed)
  files/usr/sbin/hotspotd       daemon (ucode, uloop, ubus object "wrthotspot")
  files/usr/sbin/wrthotspot     CLI
  files/usr/share/ucode/wrthotspot/   modules: core, nft, hosts, users, config, api, template, util
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
