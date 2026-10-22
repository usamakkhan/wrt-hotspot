# Architecture

WrtHotspot is a captive portal for OpenWrt 24.10 and 25.12. This page describes version 0.10.2. For installation, see the [README](../README.md); for measured behavior, see [qualification](qualification.md).

## Packages

| Package | Purpose |
|---|---|
| `wrt-hotspot` | Daemon, portal, CLI, local users and vouchers |
| `wrt-hotspot-radius` | Optional RADIUS, CoA and RouterOS API subset |
| `wrt-hotspot-shaper` | Optional tc/HTB shaping |
| `luci-app-wrt-hotspot` | Configuration and diagnostics in LuCI |
| `wrt-hotspot-panel` | Staff panel for vouchers, users, sessions and reports |
| `wrt-hotspot-full` | Installs all of the above |

The packages are architecture independent. Their runtime dependencies come from the matching OpenWrt release feeds.

## Request and packet paths

```text
Client (IPv4 or IPv6)
  |
  +--> nftables table inet wrthotspot --> OpenWrt firewall --> WAN
  |         ^
  |         +--> hotspotd updates authorization and limits
  |
  +--> uhttpd portal --> hotspotd (ubus) --> local users or optional RADIUS
                              |
                              +--> LuCI and operator panel (rpcd)
```

The kernel handles forwarding, redirection, blocking and accounting. The ucode daemon `hotspotd` handles logins, sessions, timeouts, quotas and configuration changes. A separate uhttpd instance serves portal pages. The CLI, LuCI and panel call the daemon through ubus or rpcd.

| Component | Responsibility | Source |
|---|---|---|
| `hotspotd` | Event loop, session lifecycle, polling and service state | `feed/net/wrt-hotspot/files/usr/sbin/hotspotd` |
| `core.uc` | Login, logout, restore, counters and ubus methods | `feed/net/wrt-hotspot/files/usr/share/ucode/wrthotspot/core.uc` |
| `nft.uc` | Generate and apply the hotspot ruleset | `feed/net/wrt-hotspot/files/usr/share/ucode/wrthotspot/nft.uc` |
| `portal.uc` | HTTP requests, captive API and page templates | `feed/net/wrt-hotspot/files/usr/share/wrthotspot/portal.uc` |
| `radius.uc` | Optional RADIUS requests, accounting and CoA | `feed/net/wrt-hotspot/files/usr/share/ucode/wrthotspot/radius.uc` |

## Client authorization

The hotspot identifies a device by MAC address on its hotspot interface. Authorization therefore covers its IPv4 and changing IPv6 addresses, including SLAAC privacy addresses. A binding to a single IPv6 address still matches only that address.

Unauthenticated clients can reach the portal and permitted walled-garden destinations. HTTP is redirected to the portal and DNS is directed to the router. HTTPS is not intercepted with a replacement certificate. The portal provides the RFC 8908 captive API and announces its URI through supported DHCP/RA mechanisms.

Hotspot rules live in their own `inet wrthotspot` nftables table. The daemon restores authorization state after a restart and reconciles the table after firewall reload or deletion. Flow offloading must be disabled for hotspot traffic because it bypasses accounting and limits; `wrthotspot setup` disables OpenWrt flow offloading.

Walled-garden entries can match an address/prefix, protocol and port or a DNS host. The daemon resolves hosts itself; `dnsmasq-full` adds `nftset` support for subdomains. IP bindings can bypass or block a MAC or address. A blocked host cannot reach the portal or DNS.

## Sessions, shaping and capacity

A session records its user, device, server, timeouts, byte and packet counters, and termination cause. Local users may have uptime and transfer quotas. Profiles and scheduled limitations add rates, time windows and recurring quotas. Optional RADIUS supplies authorization attributes and receives Start, Interim and Stop accounting messages. CoA and Disconnect-Request can change or end sessions.

With `wrt-hotspot-shaper`, per-user rates use tc HTB and fq_codel. Without it, nftables policing enforces rates with fewer features. Lite mode reduces process work on small routers. Its accounting and connection-cleanup tradeoffs are in [qualification](qualification.md#lite-mode).

The capacity model uses available memory, free flash and conntrack limits to calculate session and account limits. The admin can choose safe, balanced or max mode, or set explicit limits. See [qualification](qualification.md#capacity-model) for model outputs with stated inputs.

## State and recovery

Active-session checkpoints are kept in the configured `state_dir` (default `/tmp/wrthotspot`) and used to rebuild kernel state after a daemon restart. Local users, cookies and history are kept under `db_dir` (default `/etc/wrthotspot`). Usage and history writes are batched by `db_sync_interval` to reduce flash writes; administrative user edits flush immediately. A router reboot does not preserve the RAM checkpoint, so a daemon restart and a full reboot have different session-continuity guarantees.

The daemon periodically reads counters to enforce quotas and report usage. Lite mode intentionally skips a final counter read at logout; see [qualification](qualification.md#lite-mode). If nftables rejects a configured ruleset on startup, the service attempts a minimal captive ruleset rather than leaving the hotspot open.

## Configuration and interfaces

UCI configuration lives in `/etc/config/wrthotspot`. The `wrthotspot setup <network>` command adds a server entry and firewall rules, and adds DHCP/RA configuration when needed for a static network. LuCI provides configuration and diagnostics under **Services > Hotspot**. The optional panel at `http://<router>/hotspot/` gives staff access through restricted rpcd permissions.

Uploaded page sets live in `/etc/wrthotspot/pages/` and survive sysupgrade. The portal uses MikroTik-style variables and conditionals. Accepted files and size limits are in the [README](../README.md#custom-portal-pages).

## Integration boundaries

RADIUS and the RouterOS API subset require `wrt-hotspot-radius`. The API supports billing systems that use selected RouterOS commands; it is not a complete RouterOS implementation. See [billing integration](billing-integration.md) for supported commands and attributes.

Physical-router behavior and real Wi-Fi captive-portal assistants remain to be tested. The [qualification report](qualification.md) separates x86 and emulated-router results from this remaining work.
