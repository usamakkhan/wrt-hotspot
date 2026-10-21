# Qualification and benchmarks

This report separates tested results from estimates. Version 0.7.0 supplied the original x86 load measurements; the integration suites were expanded through 0.8.1, and version 0.9.0 was run on emulated MIPS and ARM routers. There are no physical-router or real Wi-Fi client results yet.

## Test environments

| Environment | OpenWrt | Resources | Purpose |
|---|---|---|---|
| x86 VM | 25.12.5 | 236 MB RAM, one vCPU | Functional, traffic and 2,000-session tests |
| QEMU malta, big-endian MIPS 24Kc | 25.12.6 and 24.10.8 | 128 MB RAM | Package install and integration suites |
| QEMU ARM Cortex-A53 | 25.12.6 | 256 MB RAM, two cores | Package install and integration suites |
| QEMU ARM Cortex-A15 | 25.12.6 | 64 MB for lite-mode measurements | Selected suites and small-router behavior |

QEMU uses OpenWrt images but does not reproduce switch chips, Wi-Fi drivers, flash wear or physical CPU speed. Measured timing in emulation should not be treated as physical-router performance.

The figures below come from different releases and workloads. A successful functional suite establishes behavior in its test topology; it does not establish throughput or capacity on a production router. No benchmark result in this report is a minimum hardware specification.

## Package and functional tests

The package build uses the official SDK for each release and produces architecture-independent packages. CI runs ucode unit tests, an nftables syntax check and package builds. The following are recorded x86 VM results from the 0.8.1 test cycle, unless noted otherwise:

| Suite | Recorded result |
|---|---|
| Unit tests, including generated nftables syntax | passed |
| Network namespace integration: portal, dual stack, walled garden, RADIUS, CoA, shaping and proxy | 154 / 154 |
| Operator panel API | 53 / 53 |
| Capacity | 16 / 16 |
| RouterOS API and independent librouteros client | 34 / 34 and 11 / 11 |
| Upgrade paths from 0.7.0 through 0.8.1 | 16 / 16 and 12 / 12 |
| Regression checks for 0.8.1 fixes | 24 / 24 |
| Real-traffic test with 150 clients | 9 / 9 |
| Control-plane load test | 2,000 / 2,000 logins |

These numbers describe the recorded suites, not a new test run for this documentation rewrite.

### Reproduce the functional suites

Run these on a dedicated OpenWrt test router with the matching packages and test dependencies. `netns-test.sh keep` sets up the temporary bridge and namespaces used by later suites; do not run it on a production router. The [test scripts](../tests/integration/netns-test.sh) document their additional dependencies and cleanup behavior.

| Result in this report | Source test | Invocation after installing the test files |
|---|---|---|
| Unit and nftables syntax | `tests/run-unit.sh` | `sh tests/run-unit.sh` |
| Network namespace integration | `tests/integration/netns-test.sh` | `sh tests/integration/netns-test.sh keep` |
| Panel API, capacity, regression | Corresponding `*-test.sh` files | `sh tests/integration/panel-api-test.sh`, `sh tests/integration/capacity-test.sh`, `sh tests/integration/regression-test.sh` |
| RouterOS API | `rosapi-test.uc`, `rosapi-librouteros.py` | `ucode tests/integration/rosapi-test.uc`; run the Python client as directed in its source |
| 150-client traffic | `traffic-test.sh` | `sh tests/integration/traffic-test.sh 150 1M/4M 1024` |
| 2,000-session control plane | `load-test.uc` | `ucode tests/integration/load-test.uc 2000 2M/10M` |

The historical x86 numbers span 0.7.0 and 0.8.1, while the QEMU table below records 0.9.0-era runs. This repository does not include immutable per-run logs or package hashes for every historical measurement, so these commands rerun the corresponding tests but cannot guarantee byte-for-byte reproduction of the reported figures. Keep the source commit, feed files, router image, configuration and raw logs together for future benchmark releases.

## Real-traffic concurrency on x86

`tests/integration/traffic-test.sh N [rate] [KiB]` gives each simulated client its own network namespace, MAC and IPv4/IPv6 addresses. Clients reach the portal, log in with vouchers, download 1 MiB over each IP family through the HTB shaper at a configured `1M/4M` rate, then log out. The reported rates are per-download observations, not aggregate capacity.

| Clients | All redirected | All logged in | Per-download rate with 4 Mbit/s limit |
|---|---|---|---|
| 20 | under 1 s | 1 s | 3.6-3.8 Mbit/s |
| 100 | 2 s | 5 s | 2.4-3.7 Mbit/s |
| 150 | 5 s | 6 s | 1.2-3.4 Mbit/s |

At 150 clients the one-vCPU VM runs the router, clients and simulated Internet side together; it is CPU-limited. Above 150 the test bed ran out of memory because the simulated clients and their curl processes lived inside the same VM. This does not establish a 150-client limit for a physical router.

The forwarding counters recorded at least the bytes delivered. They were about 13% above application payload in this test because they include packet headers and retransmissions before the shaper. This matters when comparing a data quota to an application-level download size.

## Control-plane load on x86

The packaged 0.7.0 build was tested with 2,000 neighbor entries and voucher logins on the 236 MB VM. This was a control-plane test; it did not generate full traffic from 2,000 clients.

| Metric | Recorded result |
|---|---|
| Logins | 2,000 successful, 57/s sequential, p50 14 ms, p95 20 ms |
| Poll with 2,000 sessions | 0.64 s, maximum 0.93 s, every 10 s |
| Daemon RSS | 39 MB |
| Free memory remaining | about 36 MB |
| Daemon restart and session restore | 4.7 s |
| nftables table rebuild | 120 ms |
| Logouts | 16/s sequential, p50 50 ms |

This test exposed neighbor-table, fq_codel memory, state-write and ubus paging limits. The fixes are included in the current code; see the [changelog](../CHANGELOG.md) for later changes.

The poll time is approximately linear in the session count in this VM. It should not be extrapolated directly to a small MIPS router: CPU, memory pressure, shaper choice and traffic mix change the result. Use `wrthotspot status` and router resource measurements when choosing a capacity mode.

## Capacity model

Version 0.9.0 computes limits from available memory, free flash and the conntrack table. Safe, balanced and max modes keep different memory reserves and cap sessions against conntrack capacity. The minimum is 10 sessions and 100 local accounts, with a warning if resources are that scarce. Administrators can set explicit limits.

| Example environment | Safe | Balanced | Max |
|---|---|---|---|
| Emulated 64 MB ARM router, 12-15 MB free | 55 sessions | 169 | 262 |
| 128 MB class, 75 MB free, shaped (model estimate) | 320 | 640 | 1,187 |
| 236 MB test VM, 140 MB free, shaped (model estimate) | 1,216 | 1,784 | 2,158 |

All three rows are **model outputs** for the stated inputs. The available memory in the first row was observed on an emulated ARM router; 55/169/262 are computed limits, not counts of concurrent clients successfully loaded on that router. The 2,000-session control-plane result above was measured with capacity limits disabled.

## Lite mode

Lite mode starts fewer processes for login and logout and uses nftables policing instead of tc HTB. It is selected automatically on routers with up to 64 MB RAM unless configured otherwise. It does not provide HTB burst, priority or fair queuing. It also skips the final counter read at logout, so up to one poll interval of traffic may be missed, and lets logged-out connections expire instead of flushing them.

On an emulated 64 MB ARM router, a 50-client logout test recorded p50 543 ms with lite mode and 1,648 ms without it. Emulation timing is useful for comparing those two runs on the same setup, not for predicting real hardware latency.

## Emulated-router results

The release feed installed on QEMU routers and the following suites passed:

| Router | Install | Unit | Network namespace | Regression | Capacity | Panel API | RouterOS API |
|---|---|---|---|---|---|---|---|
| 25.12.6 MIPS big-endian | apk | passed | 154/154 | 24/24 | 16/16 | 53/53 | 34/34 |
| 24.10.8 MIPS big-endian | opkg | passed | 154/154 | 24/24 | 16/16 | 53/53 | 34/34 |
| 25.12.6 ARM Cortex-A53 | apk | passed | 154/154 | 24/24 | 16/16 | 53/53 | 34/34 |

A Cortex-A15 image also passed regression, capacity and panel API checks. Testing on 24.10 MIPS found a socket-address incompatibility that prevented RADIUS, CoA and the API from working; version 0.9.0 passes address objects accepted by both releases. The MIPS runs are especially useful for checking big-endian RADIUS attribute encoding and RouterOS API word lengths.

To reproduce the QEMU workflow on a suitable Linux host:

```sh
sh tests/emu/emu.sh fetch
sh tests/emu/emu.sh boot malta &
sh tests/emu/emu.sh all malta
sh tests/emu/emu.sh status malta
```

The script also supports `malta24`, `armv8` and `armv7`. See its usage output for options and prerequisites.

`emu.sh` defaults to the project's `latest` feed, which changes over time. Set its `FEED` environment variable to an archived copy of the exact signed feed when comparing against a historical release, and record the image and source commit used. A versioned GitHub release feed URL is not a fixed archive: the project release script refreshes older feed URLs with current packages.

## Work remaining

- Test memory, poll time and HTB throughput on physical MIPS, MT7621 and IPQ40xx routers.
- Test Android, iOS, Windows and macOS captive-portal assistants over real Wi-Fi.
