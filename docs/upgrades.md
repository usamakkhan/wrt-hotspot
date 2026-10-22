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

Routine releases refresh older versioned feed URLs to serve the newest packages. Version 0.10.2 is an exception because its signing keys changed: older versioned URLs remain on 0.10.1, so routers using the old keys can still update their existing feed. Keep a separate copy of a feed when a reproducible rollback is required.

## Version 0.10.2 signing-key change

Install the new public key before updating the package index. The old key may remain installed while you migrate. If your feed URL contains an older tag such as `v0.10.1`, change that URL to `releases/latest/download` to receive 0.10.2; otherwise it will continue serving 0.10.1.

On OpenWrt 25.12 (apk):

```sh
wget -O /tmp/wrthotspot-new.pem https://github.com/usamakkhan/wrt-hotspot/releases/download/v0.10.2/wrthotspot.pem
cp /tmp/wrthotspot-new.pem /etc/apk/keys/wrthotspot.pem
apk update
apk upgrade
```

On OpenWrt 24.10 (opkg):

```sh
wget -O /tmp/wrthotspot-new.pub https://github.com/usamakkhan/wrt-hotspot/releases/download/v0.10.2/fe4302d5107a252b
opkg-key add /tmp/wrthotspot-new.pub
opkg update
opkg upgrade
```

The new public keys have SHA-256 hashes `9b341769fa2114b3f84ab0fe0612f2d04d86c66780a6244a58a2f6f3da5ccfe0` (apk) and `828a0306587e2d51d3ebbbb57118b913bb338720de43bf15100cadee059eb681` (opkg). You can compare the downloaded file with the appropriate hash using `sha256sum` before installing it.
