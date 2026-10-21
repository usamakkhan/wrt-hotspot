# Production security setup

This guide covers the WrtHotspot settings most likely to affect a real deployment. Apply changes on a test network first and verify access from a client before moving users.

## Use HTTPS for password login

The default server profile enables `http-chap`, `http-pap` and `cookie`. HTTP-PAP submits a password over HTTP. For production password logins, configure a DNS name and a certificate trusted by client devices, then enable `https` for the server profile. Once HTTPS login works from a client, remove `http-pap` from that profile if it is not required for compatibility. A captive-network detection request may still begin over HTTP; with `https` login enabled and a usable certificate, the portal redirects its login form to HTTPS before accepting the password.

In **Services > Hotspot > Servers**, set the server profile's DNS name and login methods. Point the global `ssl_certificate` and `ssl_key` settings to the installed certificate and private key. The name on the certificate must match `dns_name`. Install a supported `libustream-*` TLS library for uhttpd, reload `wrthotspot`, and run `wrthotspot check`. The check reports missing certificate files, TLS support or HTTPS listener. Confirm that a client trusts the certificate and that the form and password submission use HTTPS.

`wrthotspot cert <dns-name>` creates a self-signed certificate for testing. Browsers will warn about it; use a trusted certificate for production. RFC 8908/8910 announcements also need a configured `dns_name` and usable HTTPS certificate. See the [default UCI configuration](../feed/net/wrt-hotspot/files/etc/config/wrthotspot) for the relevant settings.

## Restrict management interfaces

- Decide which networks should reach LuCI and the operator panel. Give staff `operator` accounts unless they need to administer other panel accounts; use separate router-admin credentials.
- If you enable the built-in **Router settings** shortcut with `wrthotspot setup`, the hotspot zone allows connections to the router's web server on TCP 80 and 443. All devices on that zone can reach the LuCI login page, including clients that have not signed in to the hotspot. Use strong router credentials and decide whether this access fits your network policy.
- The optional RouterOS API uses TCP 8728 without TLS. Allow it only from the billing server or through a VPN; set `api_allow` where appropriate. The [billing guide](billing-integration.md#routeros-api-subset) lists its scope.
- Allow RADIUS CoA/Disconnect UDP 3799 only from configured billing servers. Use distinct strong RADIUS shared secrets and keep Message-Authenticator requirements enabled.
- Keep signing private keys on the build host, outside the published feed. Routers receive only public feed keys.

## Verify enforcement and recovery

Run `wrthotspot check` after changing interfaces, firewall zones, DNS, certificates or shaping packages. Flow offloading must remain disabled for hotspot accounting and limits. Confirm that an unauthenticated IPv4 **and** IPv6 client cannot reach the Internet outside the walled garden, then log in and verify access, quota behavior and logout. Test a firewall reload while a client is online.

Back up `/etc/config/wrthotspot` and `/etc/wrthotspot/` to a private location. Those paths may include credentials, users, history, custom portal pages and the portal private key. Follow the [upgrade guide](upgrades.md) before package or firmware changes.
