# Upgrades and backups

There are two different upgrade operations: updating WrtHotspot packages within an OpenWrt release, and replacing the OpenWrt firmware. Plan for the one you are doing.

## Update WrtHotspot packages

Use the feed for the router's OpenWrt release, then run `apk update && apk upgrade` on 25.12 or `opkg update && opkg upgrade` on 24.10. Check the [changelog](../CHANGELOG.md) before upgrading. The package upgrade test covers the listed older releases and checks that configuration, users and an active session survive its tested path; it does not prove every future version combination.

Before a production update, save `/etc/config/wrthotspot` and `/etc/wrthotspot/` somewhere off the router. The latter contains local user data, cookies, history and uploaded page sets. Keep the backup private because it can contain credentials and customer records. Record installed WrtHotspot package names and versions (`apk info -v` or `opkg list-installed`) so you can identify the starting point if troubleshooting is needed.

After the update, run `wrthotspot check` and `wrthotspot status`, then test one client login, access and logout. If you use RADIUS, also verify an accounting update and a disconnect request.

## Upgrade OpenWrt firmware

A firmware sysupgrade is different from a package upgrade. OpenWrt may restore selected configuration files, but packages installed after the base firmware image generally need to be installed again from feeds matching the **new** OpenWrt release. The package format also changes between 24.10 (opkg/ipk) and 25.12 (apk). Follow [OpenWrt's firmware-upgrade guide](https://openwrt.org/docs/guide-user/installation/generic.sysupgrade) for the device and release.

Before flashing:

1. Export a router configuration backup and verify it includes `/etc/config/wrthotspot` and the needed files under `/etc/wrthotspot/`. If those files are absent, copy them separately to a private off-router location. Do not assume uploaded pages, certificates or local user data are included without checking the archive.
2. Record the installed WrtHotspot package set and the feed URL and public key. Keep a copy of the compatible package feed or a way to reach it after the router comes back online.
3. Record the hotspot network interface and firewall zone. Arrange a recovery path to the router that does not depend on the hotspot portal.

After flashing, restore the configuration and data, add the feed and signing key for the new release, and reinstall the packages you used (`wrt-hotspot-full` or the selected components). Reapply setup if the network or firewall configuration was not restored. Run `wrthotspot check`, then verify the portal, a local login, and any RADIUS or operator-panel integration.

An active-session checkpoint normally lives under `/tmp/wrthotspot`; a firmware upgrade or reboot does not preserve it. Expect clients to sign in again. Do not treat the package-upgrade session test as a firmware-upgrade guarantee.

## Release feeds and signing keys

The project's release process refreshes older versioned feed URLs to serve the newest packages. A URL containing an old release tag is therefore not an archive of those package bytes. Keep a separate copy of the old feed when a reproducible rollback is required. Feed signing keys must stay consistent across routine package releases; if a key changes, routers must be configured to trust the new public key.
