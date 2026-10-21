#!/bin/sh
# Lite mode: nft policing, one nft process per login/logout. Run on the test
# router after `netns-test.sh keep` (client namespace hsclient, server hstest).
# Restores the lite option afterwards.
# (Checks call shell functions directly: functions do not exist in `sh -c`.)

PASS=0; FAIL=0
C() { ip netns exec hsclient "$@"; }
ccurl() { C curl -s -m 5 "$@"; }
ok()   { PASS=$((PASS+1)); echo "  ok    $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
check()     { d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
check_not() { d=$1; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
hs() { ubus call wrthotspot "$@"; }
online4() { [ "$(ccurl -o /dev/null -w '%{http_code}' http://10.98.0.2/)" = 200 ]; }
logout_client() { wrthotspot logout 02:00:00:00:99:10 >/dev/null 2>&1; }
reload_hs() { /etc/init.d/wrthotspot reload; sleep 3; }

OLD=$(uci -q get wrthotspot.global.lite)
cleanup() {
	logout_client
	wrthotspot user del litea >/dev/null 2>&1
	uci -q delete wrthotspot.liteprof
	if [ -n "$OLD" ]; then uci set wrthotspot.global.lite="$OLD"; else uci -q delete wrthotspot.global.lite; fi
	uci commit wrthotspot
	reload_hs
}
trap cleanup EXIT

uci set wrthotspot.liteprof=user_profile; uci set wrthotspot.liteprof.name=liteprof; uci set wrthotspot.liteprof.rate_limit=1M/2M
uci set wrthotspot.global.lite=1; uci commit wrthotspot
reload_hs
lite_on() { [ "$(hs status 2>/dev/null | jsonfilter -e '@.lite')" = true ]; }
# A slow router may still be reloading: the new profile must be known before
# the user can be created with it.
for i in $(seq 1 30); do lite_on && break; sleep 1; done
user_exists() { hs user_get '{"name":"litea"}' | jsonfilter -e '@.ok' | grep -qx true; }
for i in $(seq 1 10); do wrthotspot user add litea password=pw profile=liteprof >/dev/null 2>&1; user_exists && break; sleep 1; done
user_exists || echo "  (could not create the test user: $(wrthotspot user add litea password=pw profile=liteprof 2>&1))"

echo "== lite mode"
nft_shaper() { [ "$(hs status | jsonfilter -e '@.shaper')" = nft ]; }
check "status reports lite mode" lite_on
check "rate limits by nftables policing" nft_shaper
check "no HTB tree on the hotspot interface" sh -c "! tc qdisc show dev br-hstest | grep -q htb"

logout_client	# netns-test leaves the client logged in
sleep 1
check_not "offline before the login" online4
# Straight to hotspotd (netns-test leaves the profile on HTTPS-only logins,
# and the daemon path is what lite mode changes).
r=$(hs login '{"mac":"02:00:00:00:99:10","method":"http-pap","username":"litea","password":"pw"}')
echo "$r" | jsonfilter -e '@.ok' | grep -qx true || echo "  (login answered: $(echo "$r" | jsonfilter -e '@.error'))"
logged_in() { hs sessions | jsonfilter -e '@.sessions[*].user' | grep -qx litea; }
check "login (policers in the session's own nft batch)" logged_in
check "online" online4
limits() { nft list limits table inet wrthotspot | grep -c 'rate over'; }
two_limits() { [ "$(limits)" = 2 ]; }
check "upload and download policers in place" two_limits
logout_client
sleep 1
check_not "offline after logout" online4
no_limits() { [ "$(limits)" = 0 ]; }
check "policers removed with the session" no_limits

echo "== lite off again"
uci set wrthotspot.global.lite=0; uci commit wrthotspot; reload_hs
lite_off() { [ "$(hs status | jsonfilter -e '@.lite')" = false ]; }
check "status reports lite off" lite_off

echo "RESULT: $PASS passed, $FAIL failed"
[ $FAIL = 0 ]
