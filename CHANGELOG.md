# Changelog

This file records released changes. For installation, see the [README](README.md); for test environments and measurements, see [qualification](docs/qualification.md).

## 0.10.0 - 2026-10-21

### Added

- LuCI Quick Setup wizard for the hotspot network, portal login options and default user limits. Each step provides Save and Apply controls.
- **Router settings** links on all built-in default and classic portal pages. The link opens `http://<router-ip>/admin/`, which forwards to LuCI when installed. The portal's own `/admin` path also redirects there.
- Setup opens the router web ports from the hotspot zone when LuCI is installed. On an existing hotspot, run `wrthotspot setup <network>` after upgrading to add the firewall rule. All hotspot devices can reach the LuCI login page; router authentication remains required.
- Production security and upgrade guides, plus documentation checks in CI.

### Verified

CI passed on OpenWrt 24.10.8 and 25.12.6 for the feature commit. The new admin path and wizard have not yet been tested on a physical router.

## 0.9.0 - 2026-10-21

**Upgrade guidance:** OpenWrt 24.10 users of RADIUS, CoA or the RouterOS API should upgrade. Earlier socket binding did not work with that release's ucode socket module. The release feed is also copied to older versioned feed URLs so routers already using those URLs can upgrade.

### Added

- LuCI Login Pages management: upload a ZIP, download a page set, assign it to a server profile and remove uploaded sets. The router validates paths, file types, sizes and available flash before installation. Uploaded sets live in `/etc/wrthotspot/pages/` and survive sysupgrade.
- Built-in `classic` sample page set with an OpenWrt logo, three themes and a README of page variables.
- Capacity limits adapted for small routers, with safe, balanced and max modes and a conntrack-based cap.
- Portal worker defaults scale with RAM: 8 concurrent requests up to 64 MB, 16 up to 128 MB and 32 above that. Free memory is sampled over a rolling window so brief package installs or reloads do not abruptly shrink capacity.
- Lite mode for routers with limited RAM. It uses nftables policing and fewer processes per login and logout, with the [documented tradeoffs](docs/qualification.md#lite-mode).
- QEMU test workflow for OpenWrt MIPS and ARM images.
- Release publishing check that downloads feed indexes after publication to verify versioned URLs.

### Fixed

- RADIUS, CoA and RouterOS API socket addresses on OpenWrt 24.10.
- A zero computed capacity that was treated as unlimited when free memory fell below the reserve.
- Quoted comparisons in MikroTik-style page templates and the stock `T-` trial link.
- Slow portal rendering on emulated MIPS by reducing regular-expression and per-request configuration work.
- Portal static files now use short caching with ETag revalidation, making an uploaded page-set replacement visible sooner.
- Package metadata leaking the build host path by building from a copied feed.
- Missing signing keys now fail the build unless new keys are explicitly requested with `WRTHOTSPOT_NEW_KEYS=1`.

### Verified

Unit and integration suites ran on emulated big-endian MIPS and ARM images, including OpenWrt 24.10 and 25.12. See the [QEMU results](docs/qualification.md#emulated-router-results).

## 0.8.1 - 2026-10-20

A security and reliability update to 0.8.0. The latest-release feed URL was added, and the v0.8.0 feed URL was refreshed for existing routers.

### Security

- Restricted portal `dst=` to HTTP(S) URLs and prevented CR/LF in response headers.
- Added login and logout CSRF checks while allowing captive assistants without Origin or Referer.
- Escaped untrusted values rendered in LuCI and blocked formula injection in panel CSV exports.
- Stopped pipelined RouterOS API password guessing at the first failed login, limited repeated attempts and corrected malformed `api_allow` handling.
- Added CoA timestamp and retransmission checks and rejected malformed Calling-Station-Id values.
- Ended operator sessions after role, password or account changes.

### Reliability and behavior

- Fixed login and polling failures when the optional RADIUS package was absent.
- Limited accounting backlog delivery so a disconnected RADIUS server could not exhaust request IDs and block new logins.
- Corrected tc identifiers so the first shaped user could not cap an entire interface.
- Loaded a minimal captive ruleset if a configured nftables value was rejected.
- Preserved consumed limits across repeat logins and trials; prevented trial login from replacing a paid session.
- Prevented RADIUS cookie logins from resetting the original authorization grant.
- Made failed logins leave an existing working session intact and avoided duplicate sessions during restore.
- Improved RADIUS accounting backlog delivery and enforced the RFC 2865 password limit.
- Required a batch identifier when revoking vouchers so ordinary users could not be deleted.
- Made RouterOS API host and cookie identifiers stable and cleaned up reset connections.
- Updated setup rules when portal or proxy ports change and stopped captive announcements when disabled.
- Fixed panel time-zone grouping, duplicate batch creation, session expiration and several edit-form cases.
- Added regression coverage for the reproducible fixes.

## 0.8.0 - 2026-10-19

Added the optional RADIUS package, capacity tiers, third-party billing presets, a RouterOS API subset, transparent HTTP proxy support, signed feeds, upgrade tests and the translation template. See the [release notes](https://github.com/usamakkhan/wrt-hotspot/releases/tag/v0.8.0).
