# Design research

These notes record the choices made while designing WrtHotspot on 2026-10-17. They are historical research, not a current OpenWrt support matrix or a live comparison of competing products. Consult the [README](../README.md) for supported releases and [qualification](qualification.md) for tested behavior.

## Requirements considered

The design aimed for a dual-stack captive portal with local and RADIUS authentication, accounting, per-user shaping and a management interface that works on small OpenWrt routers. It also needed to survive firewall reloads without silently allowing unauthenticated IPv6 traffic.

The project selected OpenWrt 24.10 as its minimum target and publishes separate feeds for 24.10 (ipk/opkg) and 25.12 (apk). Package and dependency availability should be checked against each target release when building or deploying.

| Requirement | Design consequence |
|---|---|
| IPv4 and IPv6 must both be captive | Use an `inet` nftables table and test both families in the same login flow |
| One device may use many IPv6 privacy addresses | Associate authorization with its MAC on the hotspot interface |
| Router memory and flash vary widely | Keep the core package small; make RADIUS and tc shaping optional |
| Firewall reloads can replace packet rules | Reconcile hotspot state from the daemon after a reload |
| Billing systems expect MikroTik interfaces | Support selected RADIUS attributes and API commands explicitly |

## Runtime choice

The dataplane uses nftables and, when installed, tc. The daemon handles logins, timers, RADIUS and control-plane state. This keeps routine forwarding in the kernel.

ucode was chosen because it is part of the OpenWrt stack, integrates with ubus/UCI/uloop and can be packaged without compiling a binary for each CPU architecture. The optional RADIUS package adds socket and struct modules. The current package dependencies are defined in [the Makefile](../feed/net/wrt-hotspot/Makefile); the original flash and RAM estimates used to compare languages are not deployment measurements.

This choice has a cost: on slow CPUs, portal request parsing and per-session control work can be noticeable even though packet forwarding remains in the kernel. The [qualification report](qualification.md) records the later MIPS portal optimization and distinguishes emulated timing from physical performance.

## Packet-handling decisions

- **Authorize by device MAC on the hotspot interface.** A single login then covers IPv4 and changing IPv6 addresses on that device. A MAC alone is not a durable person identity, so user authentication and session limits remain separate.
- **Use a dedicated nftables table.** WrtHotspot can rebuild its state after firewall changes without editing the `inet fw4` table directly.
- **Treat both IP families as captive.** The design avoids an unauthenticated IPv6 route around an IPv4-only portal.
- **Do not impersonate HTTPS destinations.** The portal redirects HTTP, serves the RFC 8908 captive API and announces its URI where supported.
- **Disable flow offloading for hotspot traffic.** Otherwise packets can bypass accounting, quotas and shaping.
- **Use kernel counters and rate handling.** The daemon polls and manages state rather than processing each forwarded packet.

The actual ruleset and reconciliation behavior are in the [source](../feed/net/wrt-hotspot/files/usr/share/ucode/wrthotspot/nft.uc) and described in [architecture](architecture.md). Earlier syntax sketches and untested kernel assumptions were removed from this page because they could be mistaken for deployable rules.

Two constraints remain relevant to operators. First, an `accept` verdict in WrtHotspot's own table does not override a separate firewall drop, so the OpenWrt zone still needs forwarding to WAN. Second, DNS-based walled-garden entries depend on resolving and refreshing destination addresses; subdomain population works best with `dnsmasq-full` and its `nftset` support. These are reasons for the setup and diagnostics checks in the CLI.

## Compatibility scope

MikroTik Hotspot informed the login methods, page variables, RADIUS attributes and billing API subset. WrtHotspot also handles IPv6 and provides its own voucher panel. This does not imply complete RouterOS compatibility. The exact billing interfaces are listed in [billing integration](billing-integration.md).

## References used during design

- [OpenWrt release and security documentation](https://openwrt.org/docs/guide-developer/security)
- [OpenWrt firewall4 source](https://github.com/openwrt/firewall4)
- [Linux kernel flowtable documentation](https://docs.kernel.org/networking/nf_flowtable.html)
- [nftables documentation](https://wiki.nftables.org/)
- [OpenWrt rpcd source](https://github.com/openwrt/rpcd)
- [OpenWrt odhcpd source](https://github.com/openwrt/odhcpd)
- [OPNsense captive portal documentation](https://docs.opnsense.org/manual/captiveportal.html)
- [MikroTik HotSpot documentation](https://help.mikrotik.com/docs/spaces/ROS/pages/56459266/HotSpot+-+Captive+portal)

These sources supplied background. WrtHotspot's own functionality and performance claims are based on its source and the test results linked above.

## Questions for physical qualification

- How much memory and poll time do 500, 1,000 and 2,000 shaped sessions consume on representative MIPS, MT7621 and IPQ40xx devices?
- How do switch offload, Wi-Fi drivers and bridge topology affect the intended packet path on those devices?
- Do Android, iOS, Windows and macOS captive assistants display the portal reliably with a trusted certificate and RFC 8910 announcements?

These questions require physical-router and client tests; QEMU results do not answer them.
