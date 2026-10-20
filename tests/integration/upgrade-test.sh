#!/bin/sh
# Upgrade from an older release through the signed package feed (apk, 25.12+).
# Run on the test router after `netns-test.sh keep`:
#   sh upgrade-test.sh <dir with the old *.apk> <new feed dir with packages.adb + wrthotspot.pem>
# Installs the old packages, creates state (config, users, a live session,
# a RADIUS server), upgrades with signature checking and verifies it all.

OLD=${1:?old package dir}
FEED=${2:?new feed dir}
pass=0; fail=0
check() {
	if [ "$2" = 0 ]; then pass=$((pass + 1)); echo "  ok    $1 $3"; else fail=$((fail + 1)); echo "  FAIL  $1 $3"; fi
}
yes_if() { [ -n "$1" ]; echo $?; }
hs() { ubus call wrthotspot "$@"; }

echo "== install the old release"
old_ver=$(ls "$OLD"/wrt-hotspot-[0-9]*.apk | sed 's/.*wrt-hotspot-\([0-9.]*\)-r.*/\1/')
# Clean start: remove whatever is installed, keeping configuration and database.
cp /etc/config/wrthotspot /tmp/upg-config
cp -a /etc/wrthotspot /tmp/upg-db
# (apk del refuses the whole list if one name is not installed)
apk del -q $(apk info 2>/dev/null | grep -E '^(wrt-hotspot|luci-app-wrt-hotspot)') >/dev/null 2>&1
rm -f /usr/share/ucode/wrthotspot/radius.uc /usr/share/ucode/wrthotspot/rosapi.uc
cp /tmp/upg-config /etc/config/wrthotspot
rm -rf /etc/wrthotspot && cp -a /tmp/upg-db /etc/wrthotspot
apk add -q --allow-untrusted --force-overwrite "$OLD"/wrt-hotspot-[0-9]*.apk "$OLD"/wrt-hotspot-shaper-*.apk \
	"$OLD"/wrt-hotspot-panel-*.apk "$OLD"/luci-app-wrt-hotspot-*.apk 2>&1 | grep -v '^OK'
/etc/init.d/wrthotspot restart
sleep 3
check "old release $old_ver running" "$(yes_if "$(hs status | jsonfilter -e '@.version' | grep -x "$old_ver")")"

echo "== state before the upgrade"
uci set wrthotspot.global.history_size=1234
uci set wrthotspot.upgrad=radius
uci set wrthotspot.upgrad.address=127.0.0.1
uci set wrthotspot.upgrad.secret=upgrade-secret
uci commit wrthotspot
hs reload >/dev/null
wrthotspot user add upg1 password=pw comment=keep-me >/dev/null
wrthotspot user add upg2 password=pw >/dev/null
ip -6 neigh replace fd99::5:1 lladdr 02:ab:00:00:00:01 dev br-hstest nud permanent
sleep 2
hs login '{"mac":"02:ab:00:00:00:01","method":"http-pap","username":"upg1","password":"pw"}' >/dev/null
sid=$(hs sessions | jsonfilter -e '@.sessions[@.user="upg1"].id')
check "session before upgrade" "$(yes_if "$sid")"
users_before=$(hs status | jsonfilter -e '@.users')

echo "== upgrade through the signed feed"
cp "$FEED/wrthotspot.pem" /etc/apk/keys/wrthotspot.pem
mkdir -p /etc/apk/repositories.d
echo "$FEED/packages.adb" > /etc/apk/repositories.d/wrthotspot-test.list
out=$(apk update 2>&1)
check "feed index accepted (signature checked)" "$(echo "$out" | grep -qiE 'untrusted|error|BAD'; [ $? = 1 ]; echo $?)" "($(echo "$out" | tail -1))"
new_ver=$(apk search -x wrt-hotspot 2>/dev/null | sed 's/wrt-hotspot-\([0-9.]*\)-r.*/\1/')
check "RADIUS for the new core refused next to the old core" \
	"$(apk add -s wrt-hotspot-radius 2>&1 | grep -qiE 'unable to select|conflict|breaks'; echo $?)"
# Installed from files the packages are pinned to those exact files: adding
# them by name drops the pins, then they upgrade from the feed.
apk add -q wrt-hotspot wrt-hotspot-shaper wrt-hotspot-panel luci-app-wrt-hotspot 2>&1 | grep -v '^OK'
apk upgrade -q wrt-hotspot wrt-hotspot-shaper wrt-hotspot-panel luci-app-wrt-hotspot 2>&1 | grep -v '^OK'
check "all packages upgraded" "$(apk info -v 2>/dev/null | grep -E '^(wrt-hotspot|luci-app-wrt-hotspot)' | grep -vq "$new_ver"; [ $? = 1 ]; echo $?)"
/etc/init.d/wrthotspot restart
sleep 4
check "new release $new_ver running" "$(yes_if "$(hs status | jsonfilter -e '@.version' | grep -x "$new_ver")")"
check "config kept (history_size)" "$(yes_if "$(uci -q get wrthotspot.global.history_size | grep -x 1234)")"
check "users kept" "$(yes_if "$(hs status | jsonfilter -e '@.users' | grep -x "$users_before")")"
check "user details kept" "$(yes_if "$(hs user_list '{"search":"upg1"}' | jsonfilter -e '@.users[0].comment' | grep -x keep-me)")"
check "session survives the upgrade" "$(yes_if "$(hs sessions | jsonfilter -e "@.sessions[@.id='$sid'].user" | grep -x upg1)")"
check "RADIUS not available without wrt-hotspot-radius" "$(yes_if "$(hs status | jsonfilter -e '@.radius' | grep -x false)")"
check "diagnostics explain the missing RADIUS package" "$(yes_if "$(wrthotspot check | grep 'wrt-hotspot-radius is not installed')")"

apk add -q wrt-hotspot-radius 2>&1 | grep -v '^OK'
sleep 4
check "wrt-hotspot-radius from the feed restores RADIUS" "$(yes_if "$(hs status | jsonfilter -e '@.radius' | grep -x true)")"
check "session still there after adding RADIUS" "$(yes_if "$(hs sessions | jsonfilter -e "@.sessions[@.id='$sid'].user")")"
check "radius.uc owned by wrt-hotspot-radius" "$(yes_if "$(apk info -L wrt-hotspot-radius | grep radius.uc)")"
check "core package has no RADIUS files" "$(apk info -L wrt-hotspot | grep -qE 'radius.uc|rosapi.uc'; [ $? = 1 ]; echo $?)"

echo "== cleanup"
hs logout '{"mac":"02:ab:00:00:00:01","cause":"admin-reset"}' >/dev/null
ip -6 neigh del fd99::5:1 dev br-hstest
wrthotspot user del upg1; wrthotspot user del upg2
uci -q delete wrthotspot.upgrad; uci -q delete wrthotspot.global.history_size; uci commit wrthotspot
rm -f /etc/apk/repositories.d/wrthotspot-test.list
hs reload >/dev/null

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
