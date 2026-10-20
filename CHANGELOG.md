# Changelog

## 0.8.1 — 2026-10-20

Bug-fix release from a full review of 0.8.0. Upgrading is recommended for everyone.

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
