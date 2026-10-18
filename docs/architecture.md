# Architecture

Working name: **WrtHotspot** (packages `wrt-hotspot`, `luci-app-wrt-hotspot`, `wrt-hotspot-panel`). The name is a placeholder.
Background and sources: [research.md](research.md).

## 1. Goals

- MikroTik Hotspot + User Manager feature parity (~99%, matrix in §8), **dual-stack IPv4 + IPv6**.
- Runs on every OpenWrt router from 8 MB flash / 64 MB RAM MIPS up to x86; one arch-independent package.
- OpenWrt 24.10 and 25.12 (minimum 24.10: 23.05 lacks ucode-mod-socket/digest needed for RADIUS, and is EOL).
- Survives firewall reloads, daemon restarts and reboots without dropping logged-in users.
- Scales to 2000 concurrent clients on mid-range hardware (MT7621 / IPQ40xx class).
- Two GUIs: a LuCI app (configuration) and a standalone operator panel (users, vouchers, live sessions).

## 2. Components

```
                  ┌──────────────── router ─────────────────────────────────────────────┐
 client ──L2──►   │ br-hs ──► nftables  table inet wrthotspot  (kernel, all packets)   │──► WAN
 (v4 + v6)        │              ▲ sets/maps/counters (atomic `nft -f` batches)          │
                  │              │                                                       │
                  │   hotspotd (ucode, procd, uloop) ◄─ubus─► rpcd plugin ◄─► LuCI app   │
                  │     ├ sessions / timers / quotas          ▲                          │
                  │     ├ RADIUS client + CoA/DM listener      └──── operator panel (SPA)│
                  │     ├ neighbor tracker (rtnl)                                        │
                  │     ├ shaper (nft limits | tc HTB)                                   │
                  │     └ store (RAM state + debounced flash DB)                         │
                  │   uhttpd instance + ucode handler: login pages, RFC 8908 API          │
                  │   dnsmasq-full: DNS, nftset walled garden, DHCP option 114            │
                  └─────────────────────────────────────────────────────────────────────┘
```

| Package | Contents | Arch |
|---|---|---|
| `wrt-hotspot` | `hotspotd`, nft template, init script, UCI schema, default pages, RADIUS dictionary | all |
| `luci-app-wrt-hotspot` | LuCI JS views, rpcd ucode plugin, ACLs | all |
| `wrt-hotspot-panel` | standalone operator/voucher SPA served by uhttpd | all |
| `wrt-hotspot-shaper` | optional tc HTB/IFB shaping (depends on `kmod-sched-core`, `kmod-ifb`, `tc`) | all |

## 3. Dataplane (own table, never inside fw4)

- Skeleton ships as `/usr/share/nftables.d/ruleset-post/wrthotspot.nft`, so fw4 re-creates it on every load.
- A procd firewall trigger plus an `nft monitor`-free check every 10 s re-populates sets/maps after `fw4 flush`.
- **Client identity = MAC.** On `ct state new` in prerouting, `ct mark` is set from `mac2id` (MAC → client id).
  All later rules, both directions and both families, key on `ct mark`. IPv6 privacy addresses need no re-login.
- Our chains only **drop / reject / redirect / mark**; fw4's lan→wan accept does the forwarding.
- Unauthenticated clients: DNS (udp/tcp 53) redirected to the router for both families; DoT (853) dropped;
  HTTP 80 redirected to the portal; TCP 443 rejected with reset; everything else dropped unless in the walled garden.
- Walled garden: host patterns → dnsmasq `nftset=` into `wg4`/`wg6` (with timeouts); IP/CIDR/port entries → static sets.
- IP bindings: `bypassed` (MAC/IP set skipping auth), `blocked` (drop set), `regular` (normal).
- Accounting: named counters per client and direction; quotas: named quota objects; read with `nft -j`.
- **Flow offload:** the daemon refuses to start and LuCI shows an error if `flow_offloading` is enabled on a zone
  holding a hotspot interface, with a one-click "disable offload" button. Hardware offload likewise.
- Every change is one atomic `nft -f -` batch; the daemon coalesces changes for up to 100 ms.

Rule skeleton (to be validated with `nft -c` on 24.10 / 25.12):

```nft
table inet wrthotspot {
  set auth_mac   { type ether_addr; flags timeout; counter; }
  set bypass_mac { type ether_addr; }
  set block_mac  { type ether_addr; }
  map mac2id     { type ether_addr : mark; }
  set wg4 { type ipv4_addr; flags interval,timeout; }
  set wg6 { type ipv6_addr; flags interval,timeout; }
  map cnt_up   { type mark : counter; }
  map cnt_down { type mark : counter; }
  map quota_id { type mark : quota; }
  map lim_up   { type mark : limit; }
  map lim_down { type mark : limit; }

  chain mark_in { type filter hook prerouting priority mangle - 10;
    iifname @hs_ifaces ct state new ct mark set ether saddr map @mac2id }
  chain nat_pre { type nat hook prerouting priority dstnat - 10;
    iifname != @hs_ifaces return
    fib daddr type local return
    ether saddr { @auth_mac, @bypass_mac } return
    ip daddr @wg4 return
    ip6 daddr @wg6 return
    meta l4proto { tcp, udp } th dport 53 redirect to :53
    tcp dport 80 redirect to :8002 }
  chain fwd { type filter hook forward priority filter - 10; policy accept;
    iifname @hs_ifaces ether saddr @block_mac drop
    ct mark 0 iifname @hs_ifaces jump unauth
    ct mark != 0 ct direction original counter name ct mark map @cnt_up
    ct mark != 0 ct direction reply    counter name ct mark map @cnt_down
    ct mark != 0 quota name ct mark map @quota_id drop
    ct mark != 0 ct direction original limit name ct mark map @lim_up drop
    ct mark != 0 ct direction reply    limit name ct mark map @lim_down drop
    meta mark set ct mark }
  chain unauth {
    ip daddr @wg4 return
    ip6 daddr @wg6 return
    tcp dport 443 reject with tcp reset
    drop }
}
```

## 4. hotspotd (ucode daemon)

| Module | Responsibility |
|---|---|
| `config` | UCI `wrthotspot` → servers, server profiles, user profiles, walled garden, bindings, RADIUS servers |
| `nft` | builds and applies atomic batches; reconciles kernel state with daemon state on start and after flushes |
| `hosts` | host table (every MAC seen, auth or not); `rtnl` neighbor events → IPv4/IPv6 addresses per MAC |
| `sessions` | login/logout, shared-users, session/idle/keepalive timeouts, limit-uptime, limit-bytes, terminate causes |
| `auth` | local users, vouchers, MAC auth, MAC-cookie, HTTP cookie, trial, PAP/CHAP, external login page |
| `radius` | Access-Request (PAP/CHAP, Message-Authenticator), Accounting Start/Interim/Stop with gigawords, failover, CoA/DM listener on 3799, MikroTik/WISPr/Ascend VSAs |
| `shaper` | rate-limit string parser (MikroTik format); nft limit backend or tc HTB backend |
| `store` | RAM state in `/tmp`; users/vouchers/history in a flash DB with debounced, atomic writes (flash wear) |
| `hooks` | on-login / on-logout scripts with MikroTik-like variables; ubus events `wrthotspot.login`/`logout` |
| `ubus` | object `wrthotspot` used by the portal handler, rpcd plugin and CLI |

Restart safety: active sessions are checkpointed to `/tmp` (and optionally flash every N minutes); on restart the
daemon rebuilds kernel state from the checkpoint, so users stay online.

## 5. Captive portal web

- Dedicated uhttpd instance (`:8002` HTTP, `:8003` HTTPS when a certificate is set) with a ucode request handler.
- **MikroTik-compatible pages and template language:** `login.html`, `alogin.html`, `status.html`, `logout.html`,
  `error.html`, `redirect.html`, `rlogin.html`, `flogin.html`, `fstatus.html`, `flogout.html`, `radvert.html`,
  `errors.txt`, `md5.js`, language subdirectories, `$(var)` / `$(if)…$(elif)…$(else)…$(endif)`.
  Existing MikroTik hotspot themes should work unmodified.
- OS probe handling (Apple CNA, Android `generate_204`, Windows NCSI) answered correctly before and after login.
- RFC 8908 API at `/api/captive` (and MikroTik-style `api.json`); RFC 8910 via dnsmasq DHCP option 114, RA option 37
  via odhcpd where supported.
- Per-server and per-profile page sets; external login page (walled-garden host + POST back to `/login`).
- MAC randomization: optional "trust per-network MAC only" + cookie/voucher re-login; documented per OS.

## 6. GUIs

**LuCI app** (configuration, uses rpcd ucode plugin `luci.wrthotspot` + ACL):
Servers · Server profiles · User profiles (rate limit, timeouts, quotas, schedules) · Users · Walled garden ·
IP bindings · RADIUS · Pages (upload/edit/preview) · Active · Hosts · Cookies · Logs · Diagnostics (offload, dnsmasq-full, nft check).

**Operator panel** (standalone SPA, uses ubus JSON-RPC over uhttpd with its own rpcd login and a restricted ACL):
Dashboard (online users, traffic, revenue) · Vouchers (batch generate by profile, print templates, CSV export) ·
Users (add, reset, extend, disconnect) · Sessions history · Reports. Mobile-friendly; no access to router settings.

## 7. Phases

| Phase | Deliverable |
|---|---|
| 0 | Repo layout, OpenWrt feed Makefiles, CI building ipk (24.10) + apk (25.12), nft syntax checks on 24.10/25.12 |
| 1 ✓ | Dataplane + hotspotd core: hosts, MAC identity, local users, PAP/CHAP login, timeouts, accounting, IPv4+IPv6 |
| 2 ✓ | Portal pages + template engine, OS probes, RFC 8908/8910, walled garden, IP bindings, trial, cookies |
| 3 | RADIUS auth/accounting/CoA/DM + VSAs |
| 4 | Shaping (nft limits, then HTB), quotas, scheduled limitations |
| 5 | LuCI app |
| 6 | Operator panel, vouchers, printing, reports |
| 7 | Hardware qualification: MIPS 24Kc, MT7621, IPQ40xx, x86; 2000-client load test |

## 8. MikroTik parity matrix

| Area | MikroTik feature | Plan |
|---|---|---|
| Server | per-interface servers, address-pool, idle/keepalive/login timeouts, addresses-per-mac | ✓ (per interface/VLAN) |
| Server | any-IP / universal client (1:1 NAT) | ✓ IPv4 only; IPv6 not needed |
| Server profile | dns-name, hotspot-address, html-directory(-override), http-cookie-lifetime | ✓ |
| Server profile | login-by mac, cookie, http-chap, http-pap, https, trial, mac-cookie | ✓ all seven |
| Server profile | mac-auth-password, trial-uptime limit/reset, trial-user-profile, split-user-domain | ✓ |
| Server profile | smtp-server redirect | ✓ |
| Server profile | https-redirect | ✓ (default: reject 443, RFC 8908) |
| Server profile | http-proxy / transparent-proxy | ✗ deferred (no proxy in OpenWrt base) |
| Server profile | RADIUS options, interim update, location, MAC format, nas-port-type | ✓ |
| User | name/password, otp-secret, profile, server, mac lock, address, routes | ✓ (routes: deferred) |
| User | limit-uptime, limit-bytes-in/out/total, counters | ✓ |
| User profile | rate-limit full MikroTik syntax (burst, threshold, time, priority, min) | ✓ via HTB backend; nft backend = rate+burst |
| User profile | shared-users, session/idle/keepalive timeouts, status-autorefresh | ✓ |
| User profile | address-list, incoming/outgoing filter, packet marks | ✓ as nft sets / user chains |
| User profile | add-mac-cookie, mac-cookie-timeout, open-status-page | ✓ |
| User profile | advertisements (url, interval, timeout) | ✓ |
| User profile | on-login / on-logout scripts | ✓ (shell, same variables) |
| Runtime | active, host, cookie lists with remove = logout | ✓ |
| Access | ip-binding regular/bypassed/blocked, walled garden HTTP + IP | ✓ (domain + dual stack) |
| Access | walled garden by path/method | ✓ for HTTP only (HTTPS path not visible) |
| Pages | all servlet pages, variables, conditionals, languages, api.json, external login | ✓ |
| RADIUS | auth PAP/CHAP, accounting, interim, failover, CoA/Disconnect, MikroTik/WISPr/Ascend VSAs | ✓ |
| RADIUS | RadSec | deferred |
| User Manager | users, groups, profiles, limitations with time windows, vouchers, batch, templates, sessions, reports | ✓ in operator panel |
| User Manager | PayPal payments, EAP for 802.1X | ✗ out of scope (hook for payment plugin later) |
| **Beyond MikroTik** | IPv6 hotspot, RFC 8908/8910, MAC-randomization handling, GUI voucher printing, dual-stack domain walled garden | ✓ |
