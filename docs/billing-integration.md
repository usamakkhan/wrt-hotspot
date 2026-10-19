# Third-party RADIUS and billing systems

WrtHotspot speaks the RADIUS attributes and API that billing systems written for MikroTik routers
expect, so those systems can manage it too. All of this lives in the optional `wrt-hotspot-radius`
package; without it the hotspot runs on local users only (see [Small routers](#small-routers-without-radius)).

## Presets

`option radius_preset` in `config global` decides how requests look. Options in a server profile
(`radius_mac_format`, `radius_called_station`, `radius_host_ip`, `nas_port_type`) still win.

| Preset | Use for | Calling-Station-Id | Called-Station-Id | Extra |
|---|---|---|---|---|
| `mikrotik` (default) | SAS4, Radius Manager, Splynx, MikroTik User Manager, daloRADIUS/FreeRADIUS set up for MikroTik | `AA:BB:CC:DD:EE:FF` | hotspot server name | `Mikrotik-Host-IP` |
| `coova` | RADIUSdesk, HotspotSystem and other CoovaChilli/UAM billing | `AA-BB-CC-DD-EE-FF` | `<router MAC>:<server>` | |
| `generic` | plain FreeRADIUS and anything RFC-only | `AA:BB:CC:DD:EE:FF` | hotspot server name | |

Aliases are accepted too: `sas4`, `sas`, `radius-manager`, `splynx`, `usermanager`, `daloradius` →
mikrotik; `radiusdesk`, `hotspotsystem`, `chillispot` → coova; `freeradius` → generic.

## Attributes understood in Access-Accept and CoA

| Purpose | Attributes (first match wins, as on RouterOS) |
|---|---|
| Rate limit | `Mikrotik-Rate-Limit` (full syntax incl. burst, priority, limit-at) → `WISPr-Bandwidth-Max-Up/Down` (bit/s) → `ChilliSpot-Bandwidth-Max-Up/Down` (kbit/s) → `Ascend-Data-Rate` / `Ascend-Xmit-Rate` |
| Data limits | `Mikrotik-Recv/Xmit/Total-Limit` (+ `-Gigawords`), else `ChilliSpot-Max-Input/Output/Total-Octets` (+ gigawords) |
| Time | `Session-Timeout`, `Idle-Timeout`, `WISPr-Session-Terminate-Time`, `WISPr-Session-Terminate-End-Of-Day` |
| Profile / lists | `Mikrotik-Group` (user profile), `Mikrotik-Address-List`, `Filter-Id` |
| Other | `Acct-Interim-Interval`, `Port-Limit`, `Reply-Message`, `Class` (echoed in accounting) |

Accounting sends Start / Interim-Update / Stop with octets, packets, gigawords, IPv4 and IPv6
addresses, `Class`, and RouterOS terminate causes. CoA and Disconnect-Request (RFC 5176) are accepted
on udp/3799 by default (`option coa_port`).

## RouterOS API

Billing systems that manage MikroTik routers through the API (SAS4's online list, "zombie" check and
disconnect, others' user sync) work against a subset of the RouterOS API on tcp/8728:

```
config global 'global'
	option api_enable '1'
	option api_user 'billing'
	option api_password 'a-long-secret'
	# Who may connect; empty = the RADIUS servers and localhost.
	#list api_allow '192.0.2.10'
```

Admin operators of the panel can log in with their own accounts as well (plain login only). Both
logins are supported: the plain one of RouterOS 6.43+ and the older MD5 challenge.

| Menu | Commands | Notes |
|---|---|---|
| `/ip/hotspot/active` | print, remove | remove = disconnect (admin-reset) |
| `/ip/hotspot/host` | print, remove | |
| `/ip/hotspot/user` | print, add, set, remove | local users; add respects the capacity limit |
| `/ip/hotspot/user/profile`, `/ip/hotspot`, `/ip/hotspot/cookie` | print (cookie: remove) | |
| `/queue/simple` | print | one dynamic `<hotspot-user>` queue per session, with bytes and current rate |
| `/system/resource`, `/system/identity`, `/system/clock`, `/interface`, `/ip/address`, `/radius`, `/radius/incoming` | print | `version` is `api_version` (default 7.16) |
| `/ppp/active`, `/ppp/secret`, `/interface/pppoe-server` | print | always empty (no PPP here) |

Queries (`?name=x`, `?=name=x`, `?-name`, `?>bytes-in=1000`, `#|`/`#&`/`#!`), `=.proplist=`,
`=count-only=` and `.tag` work. Anything else answers `!trap` "no such command (prefix)". The API is
tested with librouteros (`tests/integration/rosapi-librouteros.py`). Not provided: SNMP (some
systems draw live graphs from it) and API-SSL (8729); put the API behind a VPN if it must cross the
internet.

## SAS4 step by step

1. On the router: install `wrt-hotspot-radius`, add the SAS server as RADIUS server and use it in
   the server profile:
   ```
   uci add wrthotspot radius
   uci set wrthotspot.@radius[-1].address='<SAS IP>'
   uci set wrthotspot.@radius[-1].secret='<secret>'
   uci set wrthotspot.@server_profile[0].use_radius='1'
   uci set wrthotspot.global.api_enable='1'
   uci set wrthotspot.global.api_user='sas'
   uci set wrthotspot.global.api_password='<api password>'
   uci commit wrthotspot && service wrthotspot reload
   ```
2. Firewall: allow udp/3799 (CoA) and tcp/8728 (API) from the SAS server to the router, e.g. a
   rule on the zone the SAS server is in.
3. In SAS4, **NAS → Add**: type *Mikrotik*, IP address = the router's address as SAS sees it,
   the same secret, *Incoming (CoA) port* 3799, *API username/password* as above, API port 8728.
4. Profiles: download/upload speed (and CIR) become `Mikrotik-Rate-Limit`; quotas and expiry are
   enforced by SAS through Session-Timeout, data limits and Disconnect-Request.
5. `wrthotspot check` lists the RADIUS servers, the CoA listener and the API.

SAS4 itself was not available for testing; the RADIUS side is tested against FreeRADIUS 3.2 with
the same attributes, the API with librouteros.

## Small routers without RADIUS

`wrt-hotspot` alone authenticates local users and vouchers (operator panel, LuCI, CLI). Leaving
out `wrt-hotspot-radius` saves about 140 KiB of installed files (the package 45 KiB,
`ucode-mod-socket` 60 KiB, `ucode-mod-struct` 37 KiB, measured on 25.12) and about 0.35 MB of daemon
memory; no RADIUS or API port is opened. RADIUS servers
in the configuration are then ignored with a warning, and `wrthotspot check` reports it. Installing
the package later turns RADIUS on without other changes.
