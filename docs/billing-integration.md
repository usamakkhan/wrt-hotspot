# Billing and RADIUS integration

The optional `wrt-hotspot-radius` package adds RADIUS authentication, accounting, CoA/Disconnect and a subset of the RouterOS API. WrtHotspot can also run with local users and vouchers without this package. SAS4 was not available for direct testing; the documented RADIUS attributes were tested with FreeRADIUS 3.2 and the API with librouteros.

## RADIUS setup

Add a RADIUS server and enable it in the server profile. The example below uses the first server profile; check the correct profile on your router before applying it.

```sh
uci add wrthotspot radius
uci set wrthotspot.@radius[-1].address='<RADIUS server IP>'
uci set wrthotspot.@radius[-1].secret='<shared secret>'
uci set wrthotspot.@server_profile[0].use_radius='1'
uci commit wrthotspot
service wrthotspot reload
wrthotspot check
```

Authentication and accounting use the RADIUS server's configured ports (1812 and 1813 by default). Allow that outbound traffic from the router. For CoA or Disconnect-Request, allow UDP port 3799 from the billing server to the router. Scope inbound firewall rules to the billing server's address. A RADIUS server entry alone does not activate RADIUS for a hotspot: its server profile must set `use_radius` to `1`. Local users are checked first; unknown users go to RADIUS.

The client sends Message-Authenticator and requires it in replies by default. Keep `require_message_auth` enabled on each RADIUS server and use a unique, strong shared secret. If authentication fails, check the NAS IP as seen by the billing server, the shared secret, selected server profile and `wrthotspot check` output before changing attributes.

## Billing presets

Set `option radius_preset` in `config global`. Server-profile options such as `radius_mac_format`, `radius_called_station`, `radius_host_ip` and `nas_port_type` override the preset.

| Preset | Typical systems | Calling-Station-Id | Called-Station-Id |
|---|---|---|---|
| `mikrotik` (default) | SAS4, Radius Manager, Splynx, User Manager, daloRADIUS | `AA:BB:CC:DD:EE:FF` | hotspot server name |
| `coova` | RADIUSdesk, HotspotSystem | `AA-BB-CC-DD-EE-FF` | `<router MAC>:<server>` |
| `generic` | plain FreeRADIUS | `AA:BB:CC:DD:EE:FF` | hotspot server name |

Aliases include `sas4`, `sas`, `radius-manager`, `splynx`, `usermanager`, `daloradius`, `radiusdesk`, `hotspotsystem`, `chillispot` and `freeradius`.

For example, a RADIUSdesk deployment can set `uci set wrthotspot.global.radius_preset='coova'`, commit `wrthotspot` and reload the service. Use `generic` for a plain RFC-only server. These presets control request identifiers and attributes; they do not install or configure the billing software.

## Authorization and accounting

WrtHotspot accepts these groups of attributes in Access-Accept and CoA:

| Purpose | Attributes |
|---|---|
| Rate | `Mikrotik-Rate-Limit`, WISPr bandwidth, ChilliSpot bandwidth, Ascend rate |
| Data quota | MikroTik receive/transmit/total limits and gigawords; ChilliSpot input/output/total octets |
| Time | `Session-Timeout`, `Idle-Timeout`, WISPr terminate time and end-of-day |
| Profile and list | `Mikrotik-Group`, `Mikrotik-Address-List`, `Filter-Id` |
| Other | `Acct-Interim-Interval`, `Port-Limit`, `Reply-Message`, `Class` |

For rate limits, MikroTik takes precedence over WISPr, then ChilliSpot, then Ascend. For data quotas, MikroTik limits take precedence over ChilliSpot limits. Accounting sends Start, Interim-Update and Stop with octets, packets, gigawords, IPv4 and IPv6 addresses, Class and termination cause. The CoA/Disconnect listener uses UDP 3799 by default.

MikroTik rate-limit syntax uses receive/transmit from the router's perspective: receive is client upload and transmit is client download. A profile rate such as `2M/10M` therefore limits a client to 2 Mbit/s upload and 10 Mbit/s download. With `wrt-hotspot-shaper` installed, burst, priority and minimum-rate fields use tc HTB; without it, nftables policing handles the basic rate. Test a profile with a real client before assigning it to a large user group.

## RouterOS API subset

Enable the API only if your billing system needs it. It listens on TCP 8728 without TLS, so restrict access to the billing server or use a VPN when it must cross an untrusted network.

```text
config global 'global'
    option api_enable '1'
    option api_user 'billing'
    option api_password 'a-long-secret'
    # Empty api_allow permits configured RADIUS servers and localhost.
    # list api_allow '192.0.2.10'
```

Plain login and the older MD5 challenge are supported. Panel admin accounts can also log in with plain login.

| Menu | Supported operations |
|---|---|
| `/ip/hotspot/active` | print, remove (disconnect) |
| `/ip/hotspot/host` | print, remove |
| `/ip/hotspot/user` | print, add, set, remove |
| `/ip/hotspot/user/profile`, `/ip/hotspot` | print |
| `/ip/hotspot/cookie` | print, remove |
| `/queue/simple` | print dynamic session queues |
| `/system/resource`, `/system/identity`, `/system/clock`, `/interface`, `/ip/address`, `/radius`, `/radius/incoming` | print |
| PPP-related menus | print returns an empty list |

Selected queries, property lists, count-only and tags work. Unsupported commands return a RouterOS `!trap`. The subset does not provide SNMP or API-SSL on 8729.

The API is a compatibility surface, not a router administration interface. It can list or change hotspot users and disconnect sessions, but PPP menus return empty results and unrelated RouterOS commands are unsupported. Check that your billing product uses only the listed commands before relying on its automation.

## SAS4 example

1. Install `wrt-hotspot-radius`, configure the SAS RADIUS server and enable RADIUS in the appropriate server profile.
2. If SAS4 uses the API, set `api_enable`, `api_user` and `api_password` as above. Permit TCP 8728 only from SAS4.
3. Permit UDP 3799 from SAS4 if CoA or disconnect is required.
4. In SAS4, add a MikroTik-type NAS using the router IP as seen by SAS4, the same RADIUS shared secret, CoA port 3799 and the configured API credentials.
5. Run `wrthotspot check` and test a login, accounting update and disconnect before using the integration with customers.

This is an interoperability recipe based on FreeRADIUS and librouteros tests, not a claim of direct SAS4 certification.

## Without RADIUS

The core package handles local users and vouchers. Without `wrt-hotspot-radius`, RADIUS settings are ignored with a warning and neither CoA nor the RouterOS API listener opens. Installing the optional package later enables those features without replacing the core configuration.
