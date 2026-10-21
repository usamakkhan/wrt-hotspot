# Changelog

## Unreleased

### Custom login pages

- **Login Pages** in LuCI: upload a zip of hotspot pages, download any page set as a zip, pick a set for a server profile, remove uploaded sets. The browser unpacks the zip, so the router needs no `unzip`. The router checks names, file types and sizes, keeps enough flash free, and installs a set only after the whole upload passed. Uploaded sets live in `/etc/wrthotspot/pages/` and survive a sysupgrade.
- New built-in page set `classic`, laid out like RouterOS's stock hotspot page, with the OpenWrt logo, links to the project, three colour themes and a README of all page variables. **Download sample** in LuCI gives it as a zip to start from.
- MikroTik page sets now really work unmodified:
  - quoted comparisons (`$(if trial == 'yes')`, `$(if error == "")`) were compared with the quotes and never matched;
  - the stock trial link (`username=T-$(mac-esc)`) starts a trial.
- The portal serves `.webp` and `.woff` files. CSS, images and scripts are cached for 2 minutes and then revalidated (ETag) instead of cached for an hour, so a replaced page set shows within 2 minutes.

### Fixes (found on emulated MIPS and ARM routers)

- **OpenWrt 24.10: RADIUS, CoA and the RouterOS API did not work.** Their sockets were bound with a `[::]:port` address string, which ucode-mod-socket on 24.10 cannot parse, so no RADIUS request was ever sent and nothing listened on 3799 or 8728. Addresses are now passed as objects, which both releases accept.
- **A router already short of memory got no session limit at all.** When the free memory was below the capacity reserve, the computed limit was 0, which means "unlimited". It now never goes below the minimum described next.

### Small routers

- **Capacity limits fit 64 MB routers.** The old model charged connection tracking to every session (96 KiB each) on top of a 16 MB reserve, so a 64 MB router got 1 session and 1 user account. Memory that all clients share and the kernel bounds anyway (the conntrack table, the portal workers) is now set aside once. A 64 MB router gets about 55 sessions in safe mode, 170 in balanced and 260 in max. At least 10 sessions and 100 accounts are always allowed, with a warning when memory is that short.
- Sessions are also capped by the conntrack table (48 / 24 / 12 connections per client by mode), so a crowd cannot fill it and break everyone's connections.
- Free memory is sampled every minute and the best of the last 10 samples counts: the limits stay steady through reloads and package installs.
- `portal_max_requests` defaults to 8 workers up to 64 MB of RAM, 16 up to 128 MB, 32 above (was 32 everywhere, up to 13 MB in a burst of new clients).
- LuCI, `wrthotspot status` and diagnostics say when the minimum applies, when the conntrack table limits, and when flash is short.
- **Faster portal on slow CPUs.** On a MIPS 24Kc the login page takes 122 ms instead of 169 ms and a CSS or image file 82 ms instead of 115 ms; rendering the pages is almost 4× faster. Regular expressions are slow in ucode on such CPUs, so the template engine and the per-request helpers now use string functions only, and the portal gets its settings from hotspotd instead of parsing the whole configuration on every request. Pages render exactly as before.

### Tests

- `tests/emu/emu.sh` boots OpenWrt in QEMU (MIPS 24Kc big-endian with 128 MB on 25.12 and 24.10, ARM Cortex-A53), installs the release feed as the README says, and runs every suite there. See [docs/qualification.md](docs/qualification.md#emulated-routers-qemu).
- The netns test brings its own minimal FreeRADIUS site, so it needs only the files, pap, chap and detail modules.
- Fewer fixed sleeps in the tests: the regression test waits for the daemon after a restart, and the CoA check polls.
- Package builds copy the feed (`src-cpy`), so package metadata no longer shows the build machine's path.

## 0.8.1 — 2026-10-20

Bug-fix release from a full review of 0.8.0. Upgrading is recommended for everyone.

Feeds: the README now installs from `releases/latest/download/`, which always serves the newest release. The v0.8.0 feed URL also serves 0.8.1, so routers set up with it upgrade with a plain `apk upgrade` / `opkg upgrade`.

### Security

- **Portal:** `dst=` only accepts plain `http(s)://` addresses, so a crafted `javascript:` link can no longer run script on the portal. CR/LF can no longer reach a response header, which blocked response splitting.
- **Portal:** another website can no longer log a device in (login CSRF) or out (logout CSRF). Captive-portal assistants, which send no Origin or Referer, still work.
- **LuCI:** user names, comments, RADIUS values and diagnostics are escaped. An operator could previously plant script that ran when an admin opened LuCI.
- **RouterOS API:**
  - pipelined password guesses stop at the first refused login;
  - an address that fails 5 times is blocked for a minute;
  - a malformed `api_allow` entry no longer matches every address.
- **RADIUS CoA/Disconnect:**
  - a request with an Event-Timestamp more than 5 minutes off is dropped;
  - a retransmission gets the cached answer and is not applied twice;
  - an unparsable Calling-Station-Id is refused instead of matching all of the user's sessions.
- **Operators:** changing an operator's role or password, or removing them, now ends their open sessions.
- **Panel CSV exports** no longer allow formula injection.

### Fixes

- Without `wrt-hotspot-radius`, logins crashed and logouts repeated on every poll, and MAC authentication could stop the daemon.
- The first shaped user after a daemon start got the HTB root class, which capped the whole interface at that user's rate. tc class, filter and leaf IDs are now kept apart. The session slot limit is 65519.
- A config value nftables refuses no longer leaves the network open at boot: a minimal captive ruleset is loaded instead. Port ranges, global ports and `dns_name` are now validated. Overlapping bypass/block networks load (`auto-merge`).
- A failed ruleset load no longer counts traffic twice.
- Limits:
  - logging in again no longer resets a used-up data or time limit;
  - repeating a trial no longer doubles it;
  - a trial can no longer replace a paid session.
- A cookie or MAC-cookie login of a RADIUS user now gets only what is left of the original grant, instead of the full Session-Timeout and data limit again.
- A failed login no longer ends the device's working session, and a new session is never left out of a fallback rebuild.
- RADIUS:
  - accounting can no longer use up all request IDs (which made every login fail while an accounting server was down);
  - the backlog is sent 32 at a time;
  - passwords are capped at the RFC 2865 limit of 128 bytes.
- `voucher_revoke` without a batch deleted ordinary users. A batch is now required.
- RouterOS API: host and cookie IDs are stable, and connection resets no longer leak slots.
- The daemon survives an exception in any timer, listener or neighbour callback, and ignores SIGPIPE.
- `wrthotspot setup` follows changes to `portal_port` and `https_port` and opens the port of a local transparent proxy. A disabled service stops announcing the portal in DHCP and RA.
- A quota typo is reported instead of meaning "unlimited", and an invalid rate-limit priority is rejected.
- Logged-out flows are dropped from conntrack when `conntrack-tools` is installed.
- Usernames starting with `T-` can log in normally.
- Panel:
  - days follow the router's time zone, so "today" is no longer yesterday east of UTC;
  - double clicks no longer create two batches;
  - the session lasts an hour and logout really ends it;
  - Extend works for accounts without an end date;
  - a profile missing from the list is no longer replaced on save.
- LuCI and panel forms refuse IP-binding and walled-garden entries the daemon would ignore, and newer searches are never overwritten by older ones.

### Tests

- New `tests/integration/regression-test.sh`, with a check for each reproducible bug above.
- RouterOS API test: pipelined login guessing.
- CI: package builds work (the scripts lacked the executable bit), lint now catches that, and actions are updated.

## 0.8.0 — 2026-10-19

- Optional RADIUS package, capacity tiers, third-party RADIUS presets and RouterOS API, transparent HTTP proxy, signed package feeds. See the [release notes](https://github.com/usamakkhan/wrt-hotspot/releases/tag/v0.8.0).
