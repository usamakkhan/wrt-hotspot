# WrtHotspot

WrtHotspot is a dual-stack captive portal for OpenWrt 24.10 and 25.12. It provides local users and vouchers, a LuCI configuration app, an optional staff panel, optional RADIUS integration and per-user traffic shaping. It is inspired by MikroTik Hotspot and supports compatible page templates and selected billing interfaces.

**Current version:** 0.10.2. CI builds and tests packages on OpenWrt x86; version 0.9.0 also passed tests on emulated MIPS and ARM routers. Physical routers and real Wi-Fi captive-portal assistants still need end-to-end testing. See [qualification](docs/qualification.md) for exact environments and results.

- [Releases](https://github.com/usamakkhan/wrt-hotspot/releases) and [issues](https://github.com/usamakkhan/wrt-hotspot/issues)
- [Architecture](docs/architecture.md)
- [Billing and RADIUS integration](docs/billing-integration.md)
- [Production security setup](docs/production-security.md)
- [Upgrades and backups](docs/upgrades.md)
- [Qualification and benchmarks](docs/qualification.md)
- [Research notes](docs/research.md)
- [Changelog](CHANGELOG.md)

<a id="install-from-the-feed"></a>

## Install

Choose the commands for your OpenWrt release. These install the complete bundle: core service, LuCI, operator panel, RADIUS and tc shaper. To use only local users and vouchers, install `wrt-hotspot` instead of `wrt-hotspot-full`.

| Package | Install it when you need |
|---|---|
| `wrt-hotspot` | The portal, CLI, local users and vouchers |
| `luci-app-wrt-hotspot` | Router configuration in LuCI |
| `wrt-hotspot-panel` | Staff accounts, voucher batches and reports |
| `wrt-hotspot-radius` | RADIUS, CoA and the RouterOS API subset |
| `wrt-hotspot-shaper` | tc HTB shaping with burst and fair queuing |
| `wrt-hotspot-full` | All of the above |

### OpenWrt 25.12 (apk)

```sh
wget -O /etc/apk/keys/wrthotspot.pem https://github.com/usamakkhan/wrt-hotspot/releases/latest/download/wrthotspot.pem
echo https://github.com/usamakkhan/wrt-hotspot/releases/latest/download/packages.adb >> /etc/apk/repositories.d/customfeeds.list
apk update
apk add wrt-hotspot-full
```

### OpenWrt 24.10 (opkg)

```sh
wget -O /tmp/wrthotspot.pub https://github.com/usamakkhan/wrt-hotspot/releases/latest/download/fe4302d5107a252b
opkg-key add /tmp/wrthotspot.pub
echo 'src/gz wrthotspot https://github.com/usamakkhan/wrt-hotspot/releases/latest/download' >> /etc/opkg/customfeeds.conf
opkg update
opkg install wrt-hotspot-full
```

The feed URLs follow the latest release. The 0.10.2 release changes signing keys; existing routers must install its new public key before updating, as described in [Upgrades and backups](docs/upgrades.md#version-0102-signing-key-change). Older versioned feed URLs remain on 0.10.1 so they continue to work with the old keys. If the repository is private, host the built feed yourself because unauthenticated routers cannot download private release assets.

## Configure a hotspot network

Create a dedicated network interface in OpenWrt first. Then run the following on the router, replacing `hotspot` with that interface's UCI name:

```sh
wrthotspot setup hotspot
service network reload
service firewall reload
service dnsmasq restart
service odhcpd restart
service wrthotspot restart
wrthotspot user add alice password=change-this-password
wrthotspot check
wrthotspot status
```

`setup` requires an existing interface in `/etc/config/network`. It adds a hotspot server and firewall access. For a static network with no DHCP section, it also adds DHCPv4, RA and DHCPv6 service. It disables flow offloading, which would bypass hotspot accounting and limits. Connect a client to the network and open an HTTP page to reach the login portal. Replace the example credentials before use.

The built-in portal pages show **Router settings** when LuCI is installed. It opens `http://<router-ip>/admin/`, which forwards to LuCI's login page. After upgrading an existing hotspot, run `wrthotspot setup <network>` and then the reload command it prints. This opens the router web ports from the hotspot zone and routes direct `/cgi-bin/luci` visits from hotspot clients to the hotspot login or status page. Devices on other networks keep the usual LuCI URL. Anyone on the hotspot network can still reach the LuCI login page through `/admin/` and must authenticate with router credentials. The portal also redirects its own `/admin` path to this shortcut.

Configure the service in **Services > Hotspot** in LuCI. If `wrt-hotspot-panel` is installed, the staff panel is at `http://<router>/hotspot/`. Create a panel account with `wrthotspot operator add <user> operator` or use `admin` for panel administration. The CLI prompts for its password.

For a guided first setup, open **Services > Hotspot > Quick Setup**. Choose an existing network and select **Save and Apply** to create its hotspot server, firewall rules and DHCP service. Then set the default portal login options and default user limits on the next two steps, using **Save and Apply** on each page. Finish by adding users and running Diagnostics. The wizard uses the default server and user profiles; the Servers and User Profiles pages offer the full set of options.

If the client does not reach the portal, run `wrthotspot check` first. It reports the daemon, firewall zone, forwarding, DHCP, portal listener, nftables table and flow-offload state. `wrthotspot status` shows sessions and capacity. For daemon messages, use `logread -e hotspotd`. A client still needs an address from the hotspot network; `setup` only creates DHCP automatically for an eligible static interface.

## Capabilities and limits

- **Access:** HTTP-PAP, HTTP-CHAP, HTTPS, MAC, trial, HTTP-cookie and MAC-cookie login; local users, vouchers, server and MAC restrictions.
- **IPv4 and IPv6:** MAC-based authorization covers a device's changing IPv6 addresses. HTTP and DNS handling, walled-garden rules and IP bindings work on both families. A binding to one IPv6 address does not cover other privacy addresses.
- **Portal:** built-in page sets, MikroTik-style template variables and conditionals, OS captive probes, RFC 8908 API and supported RFC 8910 announcements.
- **Sessions:** idle, keepalive and session timeouts; byte and packet accounting; uptime and data quotas; scheduled limitations.
- **RADIUS:** optional PAP, CHAP and MAC authentication, accounting, CoA and Disconnect-Request. The optional package also offers a limited RouterOS API for billing systems. See [billing integration](docs/billing-integration.md).
- **Rate limits:** tc HTB and fq_codel with `wrt-hotspot-shaper`; nftables policing without it. Lite mode on small routers uses policing and has [documented tradeoffs](docs/qualification.md#lite-mode).
- **Capacity:** computed session and account limits from memory, flash and conntrack capacity, with safe, balanced and max modes. The [qualification table](docs/qualification.md#capacity-model) shows model outputs for stated inputs, not guaranteed client counts.

A transparent HTTP proxy configured on the router does not contribute forwarded traffic to hotspot accounting. Place the proxy on another host if its traffic must count toward users' data limits.

The default server profile enables HTTP-CHAP, HTTP-PAP and cookies. Set up a trusted portal certificate and HTTPS password login before a production rollout; HTTP-PAP sends the password over HTTP. The [production security guide](docs/production-security.md) covers the certificate, login methods, management access and verification steps.

<a id="custom-login-pages"></a>

## Custom portal pages

Open **Services > Hotspot > Login Pages** in LuCI and download the `classic` sample. A page set needs `login.html`; it may also contain the other login, status and logout pages, CSS, JavaScript, fonts and images. Edit the sample, zip its contents, upload the archive and select the set for a server profile.

The upload accepts HTML, CSS, JS, PNG, JPEG, GIF, SVG, ICO, WebP, WOFF, WOFF2, JSON and TXT. Limits are 512 KiB per file, 2 MiB and 200 files per set. The router checks the entire upload before installing it under `/etc/wrthotspot/pages/`; uploaded sets survive sysupgrade. Missing pages fall back to the built-in defaults. RouterOS hotspot page sets can be uploaded; files outside WrtHotspot's page set are retained but ignored.

Custom pages can use `$(link-admin)` for the router-settings shortcut. It is empty if LuCI is unavailable; wrap the link in `$(if link-admin)…$(endif)` as the built-in pages do. The `classic` sample's README lists the other supported variables.

## Build and test

On a Linux host with the [OpenWrt SDK prerequisites](https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem):

```sh
git clone https://github.com/usamakkhan/wrt-hotspot.git
cd wrt-hotspot
WRTHOTSPOT_NEW_KEYS=1 scripts/build-packages.sh 24.10.8  # first build only
WRTHOTSPOT_NEW_KEYS=1 scripts/build-packages.sh 25.12.6  # first build only
```

The scripts write signed feeds under `dist/<release>/`. Signing keys live in `~/.wrthotspot-keys` or `$WRTHOTSPOT_KEYS`. On the first build of a new feed, set `WRTHOTSPOT_NEW_KEYS=1` to create its signing keys. Back them up and omit that variable on later builds: the script refuses to replace a missing key silently. A newly generated key requires existing routers to trust its new public key. Never publish a private signing key.

Run `sh tests/run-unit.sh` with ucode and its filesystem module. If nftables is installed, the script also syntax-checks the generated ruleset. Integration tests need a dedicated test device: `tests/integration/netns-test.sh` creates network namespaces and a test bridge and needs `ip-full`, `kmod-veth` and `curl`. See [qualification](docs/qualification.md) for other suites and QEMU instructions.

## Upgrades

Use `apk upgrade` on 25.12 or `opkg upgrade` on 24.10 after configuring the feed. Install `wrt-hotspot-radius` separately if upgrading an older file-installed setup that used RADIUS. The [upgrade test](tests/integration/upgrade-test.sh) covers preservation of sessions, users and configuration across the tested package versions. An OpenWrt firmware sysupgrade has different backup and reinstall requirements; follow [Upgrades and backups](docs/upgrades.md) before flashing.

## License and trademarks

GPL-2.0-or-later; see the package Makefiles. WrtHotspot is independent of MikroTik and is not affiliated with or endorsed by it. MikroTik and RouterOS are their owners' trademarks; compatible attribute and API names describe interoperability.
