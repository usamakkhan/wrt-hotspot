WrtHotspot login page set
=========================

A page set is a folder of HTML pages (plus CSS, images and scripts) that the
captive portal shows to hotspot users. This is the "classic" set that ships
with WrtHotspot. Edit it, zip it and upload it under
LuCI > Services > Hotspot > Login Pages.

Project:  https://github.com/usamakkhan/wrt-hotspot
Docs:     https://github.com/usamakkhan/wrt-hotspot#custom-portal-pages
Issues:   https://github.com/usamakkhan/wrt-hotspot/issues


Pages
-----
login.html    login form (required)
alogin.html   shown right after a successful login
status.html   status of a logged-in user
logout.html   shown after logging out
flogout.html  logout requested by a user who is not logged in
fstatus.html  status requested by a user who is not logged in

A page missing from your set falls back to the built-in default page.
Other files (css/, img/, md5.js) are served as they are. Allowed types:
html css js png jpg jpeg gif svg ico webp woff woff2 json txt.
Limits: 512 KiB per file, 2 MiB and 200 files per set.

Use relative links (css/style.css, img/logo.svg): the pages are served from
the portal's root, so they also work over HTTPS and on a custom DNS name.


Variables
---------
Pages use the MikroTik hotspot syntax, so RouterOS page sets work too:

  $(name)                  value of a variable, HTML-escaped
  $(name-raw)              value without escaping (only for trusted values)
  $(if name) ... $(elif name == 'x') ... $(else) ... $(endif)
  $(if name != 'x') ...    compare with == or != (quotes are optional)

Common variables:
  identity, hostname, server-name, ip, mac, ipv6, username, error,
  logged-in (yes/no), trial (yes/no), login-by,
  link-login, link-login-only, link-logout, link-status, link-orig,
  link-orig-esc, link-redirect, mac-esc, user-esc,
  chap-id, chap-challenge, plain-passwd, ssl-login,
  uptime, uptime-secs, session-time-left, session-time-left-secs,
  idle-timeout, bytes-in, bytes-out, bytes-in-nice, bytes-out-nice,
  remain-bytes-in, remain-bytes-out, refresh-timeout, refresh-timeout-secs

Login form fields (POST to $(link-login-only)):
  username, password, dst = $(link-orig)
  trial=yes for a free trial (MikroTik's username=T-$(mac-esc) also works)

With HTTP CHAP (when $(chap-id) is set) send
hexMD5('$(chap-id)' + utf8Bytes(password) + '$(chap-challenge)') as the
password; md5.js provides both functions. login.html shows how.


Themes
------
style.css has three colour themes: <body>, <body class="lite"> and
<body class="dark">. Replace img/logo.svg with your own logo.
