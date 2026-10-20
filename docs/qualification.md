# Qualification (Phase 7)

Status 2026-10-18, version 0.7.0. No physical routers were available, so everything below was measured on the
x86-64 test VM (OpenWrt 25.12.5, 236 MB RAM, 1 vCPU). The MIPS/ARM rows stay open until hardware is
at hand; the packages themselves are architecture independent (ucode, JS, HTML).

## Packages

`scripts/build-packages.sh <release>` builds every package with the official x86-64 SDK of that
release and copies them to `dist/<release>/`. The packages are `PKGARCH:=all`, so the same files
install on every target of the release. Only the luci-base host tools are compiled besides our own
packages (`NO_DEPS=1`): runtime dependencies such as tc-full or luci-base come from the router's
package feeds.

| Release | Format | Result |
|---|---|---|
| 24.10.8 | ipk | 4 packages, ~1 min with a warm SDK |
| 25.12.6 | apk | 4 packages, ~1 min with a warm SDK; installed with `apk add` on the VM and every suite below re-run against the packaged files |

CI (`.github/workflows/ci.yml`) runs the unit tests inside the OpenWrt 24.10 and 25.12 rootfs images
(the real ucode and nft of each release), lints shell/JSON/JS, and builds both package sets.

## Test suites (on the VM, 0.8.1)

| Suite | Result |
|---|---|
| `tests/run-unit.sh` (incl. capacity maths and `nft -c` of the generated ruleset) | all passed |
| `tests/integration/netns-test.sh` (portal, IPv4/IPv6, walled garden, RADIUS + presets + ChilliSpot/Ascend, CoA, shaping, transparent proxy, RFC 8908/8910) | 154 / 154 |
| `tests/integration/panel-api-test.sh` (operator roles, vouchers, history, reports, capacity force) | 53 / 53 |
| `tests/integration/capacity-test.sh` (limits, admin force, override) | 16 / 16 |
| `tests/integration/rosapi-test.uc` (RouterOS API, incl. pipelined login guessing) + `rosapi-librouteros.py` (independent client) | 34 / 34, 11 / 11 |
| `tests/integration/upgrade-test.sh` (0.7.0 → 0.8.0 and 0.8.0 → 0.8.1 through the signed feed) | 16 / 16, 12 / 12 |
| `tests/integration/regression-test.sh` (one check per bug fixed in 0.8.1) | 24 / 24 |
| `tests/integration/traffic-test.sh 150` (below) | 9 / 9 |
| `tests/integration/load-test.uc 2000` (capacity limits off for the run) | 2000 / 2000 logins |

## Real-traffic concurrency test

`tests/integration/traffic-test.sh N [rate] [KiB]` (after `netns-test.sh keep`): N clients, each in
its own network namespace with its own MAC, IPv4 and IPv6 address, plugged into the hotspot bridge.
All of them at the same time are redirected, log in through the portal with a voucher (real HTTP
POST through uhttpd), download 1 MiB over IPv4 and 1 MiB over IPv6 through the HTB shaper (profile
`1M/4M`), and finally log out through the portal.

| Clients | Redirect (all) | Login (all) | Result | Per-download rate (limit 4 Mbit/s) |
|---|---|---|---|---|
| 20 | < 1 s | 1 s | 9 / 9 | 3.6–3.8 Mbit/s |
| 100 | 2 s | 5 s | 9 / 9 | 2.4–3.7 Mbit/s |
| 150 | 5 s | 6 s | 9 / 9 | 1.2–3.4 Mbit/s (VM CPU is the limit: router, 150 clients and the "internet" share one vCPU) |

Every session accounted at least the bytes delivered; the counters run ~13% above the payload
(IP/TCP headers plus the retransmissions of packets the shaper dropped, which the forward hook
counts before the shaper). No client ever exceeded its limit.

Above 150 clients the VM itself runs out of memory: each simulated client costs ~234 KiB of kernel
memory (namespace + veth) plus its curl process, all inside the router's 236 MB. That's a limit of
the test bed, not of the router (real clients bring their own RAM), but it surfaced two real issues:

| Found with 200 clients | Fix |
|---|---|
| The OOM killer picked `hotspotd` (largest process), dropping the sessions of the last second | `hotspotd` sets `oom_score_adj -500`: a portal worker or a tool goes first; verified, the daemon now survives and only workers are killed |
| Each concurrent portal request is a forked uhttpd worker (~0.4 MB) | bounded by `-n`, now the `portal_max_requests` option (default 32 ≈ 12 MB peak; 8–16 on 64 MB routers) |

Portal throughput on the VM: ~16 ms per request (fork + ucode handler, the same for redirects, the
login page and static files), about 60 requests/s per core; 200 simultaneous fresh clients are all
redirected within ~7 s.

## 2000-client control-plane load test

`tests/integration/load-test.uc 2000 2M/10M` (after `netns-test.sh keep`): 2000 simulated clients,
each a neighbor entry with its own MAC, all logged in with vouchers from a rate-limited profile.
That's the worst case: every session gets two HTB classes, two flower filters and an fq_codel leaf.

| Metric | Result |
|---|---|
| Hosts learned via rtnetlink | 2000 / 2000 |
| Voucher creation | 2000 in 0.3 s |
| Logins (sequential) | 2000 ok, 57/s, p50 14 ms, p95 20 ms |
| Poll cycle with 2000 sessions | 0.64 s (max 0.93 s), poll every 10 s |
| Daemon RSS | 39 MB (+28 MB for 2000 sessions) |
| tc classes / filters | 2000 + 2000 (download on the bridge, upload on the IFB) |
| Free memory left | ~36 MB of 236 MB |
| Session list | paged, 1000 per ubus call |
| Daemon restart | all 2000 sessions back after 4.7 s, no duplicates |
| Dataplane rebuild (table deleted) | 120 ms nft transaction, 285 KiB ruleset |
| Logouts (sequential) | 16/s, p50 50 ms; all tc classes removed |

(Measured on the packaged 0.7.0 build.)

### Problems found and fixed

| Problem at scale | Fix |
|---|---|
| Only ~500 of 2000 hosts seen | kernel neighbor table capped at `gc_thresh3` 1024 → `/etc/sysctl.d/12-wrthotspot.conf` raises it to 8192 (IPv4) / 16384 (IPv6); lost netlink bursts → on-demand lookup at login + resync every 30 s |
| OOM kill at ~900 shaped sessions | default fq_codel leaf allocates 1024 flows (~1 MB/class) → leaf sized `flows 64 limit 300 memory_limit 512Kb` |
| Login latency rising to 130 ms | user database written on every first login → debounced (1 s checkpoint, 5 s users) |
| `sessions` call timing out | ubus messages are limited to 1 MiB → all list methods are paged (`offset`, `limit`, `search`); CLI, LuCI and panel page through them |
| 4000 sessions after restart | auto-login ran before session restore → logins held until start-up completes; restore drops duplicate MACs |
| 30 s restart | old ubus object stayed registered during shutdown → removed first |
| Poll 1.25 s at 2000 sessions | parse caches, per-second limitation cache, rate/prune work every 30 s → 0.67 s |

## Capacity tiers (0.8.0)

The router now computes its own limits (`capacity.uc`) instead of relying on a table like the one
that used to be here. Costs measured with `tests/integration/capacity-probe.uc 1000` on 25.12:

| Item | RAM per item | of which daemon |
|---|---|---|
| local user account | 4.4 KiB | 3 KiB (+ ~0.45 KiB in `users.json` on flash) |
| learned host | 5 KiB | 2 KiB |
| session, nft policing / no limit | 18 KiB | 8 KiB |
| session, tc HTB shaping | 37 KiB | 3 KiB |

Model: budget = available memory at start + what the hotspot already uses − reserve; 85% of it goes
to sessions, 15% to accounts, and accounts are also limited to half of the free flash.

| Mode | Reserve kept free | Traffic allowance per session | Shaped session counted as |
|---|---|---|---|
| safe (default) | 30% of RAM, at least 16 MB | 96 KiB | 141 KiB |
| balanced | 20%, at least 12 MB | 48 KiB | 93 KiB |
| max | 12%, at least 8 MB | 16 KiB | 61 KiB |

The traffic allowance covers what a busy client adds outside the hotspot (conntrack entries, socket
and queue memory). What that gives (shaped, typical free memory after boot):

| Router | RAM / free | safe | balanced | max |
|---|---|---|---|---|
| 64 MB MIPS | 59 / 25 MB | 44 sessions | 116 | 234 |
| 128 MB MT7621 / IPQ40xx | 123 / 75 MB | 229 | 460 | 839 |
| test VM | 236 / 140 MB | 415 | 846 | 1554 (2000 measured working without traffic) |

Logins beyond the limit are refused with "the hotspot is full", unless `capacity_override` is set;
user accounts beyond it need an admin to confirm (LuCI, panel, `force=1` in the CLI). Status,
diagnostics, LuCI (Settings → Capacity) and `wrthotspot status` show tier, mode and usage.

The poll cycle grows linearly (~0.3 ms per session on the VM); expect 3–5× that on MIPS, so leave
`poll_interval` at its 10 s default (or raise it) above ~500 sessions.

Portal bursts: every unauthenticated device's captive probes reach the portal, so a crowd arriving at
once (a lecture hall, a bus) costs `portal_max_requests` × ~0.4 MB at peak; lower it on small routers.

Logging: every login/logout is logged at `info`. With hundreds of logins a minute the default 64 KiB
logread ring wraps quickly — use remote syslog or raise `log_size` on busy sites.

## Still open

- Real MIPS 24Kc, MT7621 and IPQ40xx routers: memory, poll time and HTB throughput on each.
- Real Wi-Fi clients (Android, iOS, Windows, macOS captive-portal assistants) end to end.
