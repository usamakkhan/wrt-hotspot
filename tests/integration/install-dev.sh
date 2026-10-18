#!/bin/sh
# Install the package files from a source checkout onto a router (dev only).
set -e
SRC=$(cd "$(dirname "$0")/../../feed/net/wrt-hotspot/files" && pwd)
[ -f /etc/config/wrthotspot ] || cp "$SRC/etc/config/wrthotspot" /etc/config/wrthotspot
cp "$SRC/etc/init.d/wrthotspot" /etc/init.d/wrthotspot && chmod 0755 /etc/init.d/wrthotspot
cp "$SRC/usr/sbin/hotspotd" /usr/sbin/hotspotd && chmod 0755 /usr/sbin/hotspotd
cp "$SRC/usr/sbin/wrthotspot" /usr/sbin/wrthotspot && chmod 0755 /usr/sbin/wrthotspot
mkdir -p /usr/share/ucode/wrthotspot /usr/share/wrthotspot/pages/default
cp "$SRC"/usr/share/ucode/wrthotspot/*.uc /usr/share/ucode/wrthotspot/
cp "$SRC/usr/share/wrthotspot/portal.uc" /usr/share/wrthotspot/
cp "$SRC"/usr/share/wrthotspot/pages/default/* /usr/share/wrthotspot/pages/default/
echo "installed"
