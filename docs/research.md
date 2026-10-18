# Research: building a MikroTik-class hotspot for OpenWrt

Date: 2026-10-17. Four research tracks: runtime stack, prior art, nftables/IPv6 dataplane, MikroTik feature set.
Items marked **[unverified]** must be tested on hardware before we rely on them.

## 1. OpenWrt release landscape

| Release | Status (openwrt.org/docs/guide-developer/security) | Kernel | nft | Package format |
|---|---|---|---|---|
| 23.05 | EOL since 2025-08 (last 23.05.6) | 5.15 | 1.0.8 | opkg `.ipk` |
| 24.10 | projected EOL 2026-09 (last 24.10.8) | 6.6 | 1.1.1 | opkg `.ipk` |
| 25.12 | the only supported release (25.12.6) | 6.12 | 1.1.x | apk `.apk` |

Decision: minimum target is 24.10; 25.12 first-class. 23.05 is dropped (EOL, and it lacks ucode-mod-socket/digest needed for RADIUS).
The feed must publish both an ipk tree (usign key) and an apk tree (apk key).

## 2. Runtime stack

The packet path is entirely in the kernel (nftables sets/maps, tc). The daemon only handles logins, timers,
RADIUS and the web pages, so the language decides footprint and portability, not throughput.

| | ucode | Lua 5.1 | C (libubox) | Go | Rust |
|---|---|---|---|---|---|
| Extra flash | ~60 KB | ~150 KB | 50–150 KB | 2–8 MB | 0.5–2 MB |
| RAM (est.) | 1–3 MB | 1–3 MB | <1 MB | 5–15 MB [unverified] | 1–3 MB |
| Build per CPU arch | no (`PKGARCH:=all`) | no | yes, per release | yes | yes, MIPS is Tier 3 |
| Already on every image | **yes** (fw4, hostapd, LuCI backend) | no (optional since 23.05) | libs yes | no | no |
| Dev speed | high | high | low | high | medium |

ucode module availability (official feeds, mips_24kc):

| Module | 23.05 | 24.10 | 25.12 | Used for |
|---|---|---|---|---|
| uloop, ubus, uci, fs, rtnl, nl80211, struct, log, math | yes | yes | yes | event loop, IPC, config, neighbor table, Wi-Fi |
| **socket** | **no** (source present in 23.05's ucode) | yes | yes | RADIUS UDP, CoA listener |
| **digest** | **no** | yes | yes | MD5 for CHAP / RADIUS |
| uhttpd-mod-ucode | yes | yes | yes | captive web server |
| rpcd-mod-ucode | yes | yes | yes | LuCI + panel backend |

**Choice: ucode**, on 24.10+ where every needed module is in the official feeds. `digest` has no HMAC; HMAC-MD5 (Message-Authenticator, needed against BlastRADIUS) is built from
two MD5 calls. A small C helper is kept as an option only if profiling shows a need.

## 3. Prior art

| Project | Dataplane | IPv6 | RADIUS | Shaping | Status |
|---|---|---|---|---|---|
| openNDS | nftables, own tables | partial; IPv6-only unsupported (#625) and bypass over IPv6 (#706) | none (scripts) | packets/min limit | active, 1 maintainer, feed lags |
| nodogsplash | iptables | none (#38, open since 2014) | no | no | stale |
| CoovaChilli | tun + optional kernel module | none (#587) | full incl. CoA/DM | in-daemon bucket | slow, 200+ open issues |
| apfree-wifidog | nftables + eBPF | per (MAC, IPv6) rule | not found | eBPF | active |
| pfSense CP | ipfw/dummynet | none (Redmine #1831, since 2011) | auth+acct | dummynet | IPv6 missing |
| OPNsense CP | pf | **full**, MAC "roaming" | auth+acct | ipfw | active |
| MikroTik Hotspot | proprietary | **none** ("works reliably only when IPv4 is used") | full incl. CoA | simple queues | — |

No OpenWrt project combines nftables, full IPv6, full RADIUS (with CoA) and real per-user shaping. That is the gap.

### Lessons that shape the design
1. **Default-deny both families from day one.** IPv6 bypass is the most common real-world failure (openNDS #706).
2. **Authorize by MAC, not by IP.** SLAAC privacy addresses then work with no re-login (only OPNsense does this today).
3. **Use our own nft table, never rules inside `inet fw4`.** fw4 reload only rebuilds `inet fw4`; but
   `/etc/init.d/firewall stop` runs `fw4 flush`, which deletes *every* table, so the daemon must re-apply its state.
4. **Use sets/maps updated in atomic batches**, never one `nft` process per client rule (openNDS #738 leaked rules).
5. **Flow offloading silently breaks accounting, quotas and shaping** (openNDS #530). fw4 puts its `flow offload`
   rule first in its forward chain, so another table cannot exclude clients. Offload must be off on hotspot traffic.
6. **Proper RADIUS incl. CoA/Disconnect** — only CoovaChilli has it among open projects.
7. **Never intercept TCP/443.** Reject it with TCP reset for unauthenticated clients, announce the portal via
   RFC 8910 and serve the RFC 8908 API; keep the HTTP redirect as the fallback.

## 4. Dataplane findings (nftables, kernel 5.15+)

- `ether saddr` is only available on the input path (prerouting/input/forward of received frames), not on replies.
  **Pattern: identify the client by MAC once on `ct state new` in prerouting and set `ct mark` = client id.**
  Everything else (both directions, both families, accounting, shaping) keys on `ct mark`.
- Per-element counters in sets: kernel 5.7+. Named counter / quota / limit objects selected by map
  (`counter name ct mark map @m`): syntax must be checked with `nft -c` on nft 1.0.8 and 1.1.1 **[unverified]**.
- An `accept` in our table does not override fw4's `drop`. Our table only drops, rejects, redirects or marks.
- `redirect` works for IPv6 in `inet` nat chains on 5.15/6.6 (DNS hijack + HTTP redirect for both families).
- Walled garden by domain: dnsmasq `nftset=` (dnsmasq-full ≥ 2.87; early 23.05 shipped 2.86).
- RFC 8910: DHCPv4 option 114 via dnsmasq works everywhere. odhcpd's `captive_portal_uri` (DHCPv4/DHCPv6/RA option 37)
  is only in recent odhcpd master **[unverified on 24.10/25.12]**; otherwise we send RA option 37 ourselves or skip it.
- Shaping options:
  - nft `limit` objects per client (policing, drops over rate): cheap at 2000 clients, TCP-unfriendly.
  - HTB per client: download on LAN egress with `fw` filter on skb->mark; upload on WAN egress or IFB with
    `act_ctinfo` restoring the mark. Close to MikroTik simple queues (rate, burst, priority, min-rate).
- Accounting: named counters per client in each direction, read with `nft -j list counters`; RADIUS
  gigawords handled by the daemon.

## 5. MikroTik feature catalog

The full property-level catalog (servers, server profiles, users, user profiles, active/host/cookie, ip-binding,
walled garden, servlet pages and variables, RADIUS attributes and VSAs, CoA, User Manager) is the parity checklist in
[architecture.md §8](architecture.md#8-mikrotik-parity-matrix).

MikroTik gaps we can fill: IPv6; MAC randomization handling; GUI voucher batches and printing; RFC 8908/8910;
a dual-stack walled garden by domain.

## Sources
- Release status: https://openwrt.org/docs/guide-developer/security
- Package indexes: https://downloads.openwrt.org/releases/{23.05.5,24.10.4,25.12.6}/packages/mips_24kc/base/
- fw4: https://github.com/openwrt/firewall4 (`root/sbin/fw4`, `templates/ruleset.uc`, `etc/init.d/firewall`)
- nftables: https://wiki.nftables.org (Matching_packet_headers, Sets, Configuring_chains, kernel updates list)
- Flowtable: https://docs.kernel.org/networking/nf_flowtable.html
- rpcd ucode plugins: https://github.com/openwrt/rpcd/blob/master/ucode.c
- odhcpd: https://github.com/openwrt/odhcpd/blob/master/README.md ; RFC 8908/8910
- openNDS issues #530 #596 #625 #628 #698 #706 #708 #738; nodogsplash #38; coova-chilli #587 #493 #477; pfSense Redmine #1831
- OPNsense captive portal: https://docs.opnsense.org/manual/captiveportal.html
- MikroTik: help.mikrotik.com pages *HotSpot – Captive portal*, *Hotspot customisation*, *RADIUS*, *User Manager*
