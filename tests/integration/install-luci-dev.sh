#!/bin/sh
# Install the LuCI app from a source checkout onto a router (dev only).
set -e
SRC=$(cd "$(dirname "$0")/../../feed/luci/luci-app-wrt-hotspot" && pwd)
mkdir -p /www/luci-static/resources/view/wrthotspot /www/luci-static/resources/tools
cp "$SRC"/htdocs/luci-static/resources/view/wrthotspot/*.js /www/luci-static/resources/view/wrthotspot/
cp "$SRC"/htdocs/luci-static/resources/tools/wrthotspot.js /www/luci-static/resources/tools/
cp "$SRC"/root/usr/share/luci/menu.d/luci-app-wrt-hotspot.json /usr/share/luci/menu.d/
cp "$SRC"/root/usr/share/rpcd/acl.d/luci-app-wrt-hotspot.json /usr/share/rpcd/acl.d/
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null || true
/etc/init.d/rpcd reload
echo "luci app installed"
