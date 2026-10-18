#!/bin/sh
# End-to-end test on a real OpenWrt box (dedicated test device only!).
#
#  netns hsclient --veth-- br-hstest [router, hotspot "hstest"] hsi0p --veth-- netns hsinet (web server)
#  10.99.0.10 fd99::10/fd99::beef     10.99.0.1 fd99::1   10.98.0.1 fd98::1      10.98.0.2 fd98::2
#
# Needs ip-full, kmod-veth, curl.
# Usage: netns-test.sh          run, then tear everything down
#        netns-test.sh keep     leave the topology up afterwards
#        netns-test.sh cleanup  tear down only

PORT=8002
P="http://10.99.0.1:$PORT"
PASS=0
FAIL=0

C() { ip netns exec hsclient "$@"; }
I() { ip netns exec hsinet "$@"; }
ccurl() { C curl -s -m 5 "$@"; }

ok()  { PASS=$((PASS+1)); echo "  ok    $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
check()     { d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
check_not() { d=$1; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }

code_is() { [ "$(ccurl -o /dev/null -w '%{http_code}' "$@")" = 200 ]; }
online4()  { code_is http://10.98.0.2/; }
online6()  { code_is 'http://[fd98::2]/'; }
online6b() { code_is --interface fd99::beef 'http://[fd98::2]/'; }
redirected4() { ccurl -o /dev/null -w '%{http_code} %{redirect_url}' http://10.98.0.2/x | grep -q "^302 $P/login?dst="; }
redirected6() { ccurl -o /dev/null -w '%{http_code} %{redirect_url}' 'http://[fd98::2]/x' | grep -q "^302 http://\[fd99::1\]:$PORT/login?dst="; }
page_has()  { ccurl "$1" | grep -q "$2"; }
post_has()  { ccurl -d "$1" "$P/login" | grep -q "$2"; }
poll_wait() { sleep 3; }

cleanup() {
	ip netns del hsclient 2>/dev/null
	ip netns del hsinet 2>/dev/null
	ip link del hsc0p 2>/dev/null
	ip link del hsi0p 2>/dev/null
	uci -q delete network.hstest
	uci -q delete network.hsinet
	uci -q delete network.br_hstest
	for s in $(uci show firewall | grep -E "\.(name|src)='(hstest|hsinet|Allow-hstest-[A-Za-z0-9]+)'" | cut -d. -f2 | sort -u); do
		uci -q delete "firewall.$s"
	done
	uci -q delete wrthotspot.hstest
	uci -q delete wrthotspot.testprof
	uci -q del_list wrthotspot.@server_profile[0].login_by=trial
	uci -q set wrthotspot.global.poll_interval=10s
	uci -q set wrthotspot.@server_profile[0].trial_uptime_limit=30m
	uci commit network
	uci commit firewall
	uci commit wrthotspot
}

setup() {
	cleanup

	ip netns add hsclient
	ip netns add hsinet
	ip link add hsc0 type veth peer name hsc0p
	ip link set hsc0 netns hsclient
	ip link add hsi0 type veth peer name hsi0p
	ip link set hsi0 netns hsinet

	C ip link set lo up
	C ip link set hsc0 address 02:00:00:00:99:10 up
	C ip addr add 10.99.0.10/24 dev hsc0
	C ip route add default via 10.99.0.1
	C ip -6 addr add fd99::10/64 dev hsc0 nodad
	C ip -6 addr add fd99::beef/64 dev hsc0 nodad
	C ip -6 route add default via fd99::1

	I ip link set lo up
	I ip link set hsi0 up
	I ip addr add 10.98.0.2/24 dev hsi0
	I ip route add default via 10.98.0.1
	I ip -6 addr add fd98::2/64 dev hsi0 nodad
	I ip -6 route add default via fd98::1
	mkdir -p /tmp/hsinet-www
	echo "hello from the internet" > /tmp/hsinet-www/index.html
	I uhttpd -p 0.0.0.0:80 -p '[::]:80' -h /tmp/hsinet-www

	uci set network.br_hstest=device
	uci set network.br_hstest.type=bridge
	uci set network.br_hstest.name=br-hstest
	uci add_list network.br_hstest.ports=hsc0p
	uci set network.hstest=interface
	uci set network.hstest.proto=static
	uci set network.hstest.device=br-hstest
	uci set network.hstest.ipaddr=10.99.0.1/24
	uci set network.hstest.ip6addr=fd99::1/64
	uci set network.hsinet=interface
	uci set network.hsinet.proto=static
	uci set network.hsinet.device=hsi0p
	uci set network.hsinet.ipaddr=10.98.0.1/24
	uci set network.hsinet.ip6addr=fd98::1/64
	uci commit network

	z=$(uci add firewall zone)
	uci set firewall.$z.name=hsinet
	uci add_list firewall.$z.network=hsinet
	uci set firewall.$z.input=ACCEPT	# simulated internet: allow its ICMPv6 ND to the router
	uci set firewall.$z.output=ACCEPT
	uci set firewall.$z.forward=REJECT
	uci commit firewall

	wrthotspot setup hstest
	f=$(uci add firewall forwarding)
	uci set firewall.$f.src=hstest
	uci set firewall.$f.dest=hsinet
	uci commit firewall

	uci set wrthotspot.global.poll_interval=2s
	uci set wrthotspot.testprof=user_profile
	uci set wrthotspot.testprof.shared_users=1
	uci set wrthotspot.testprof.keepalive_timeout=0
	uci add_list wrthotspot.@server_profile[0].login_by=trial
	uci set wrthotspot.@server_profile[0].trial_uptime_limit=6s
	uci commit wrthotspot

	/etc/init.d/network reload
	sleep 5
	/etc/init.d/firewall reload >/dev/null 2>&1
	/etc/init.d/wrthotspot enable
	/etc/init.d/wrthotspot restart
	sleep 3
	wrthotspot user add alice password=secret profile=testprof >/dev/null
	wrthotspot user add bob password=bobpw limit_uptime=5s profile=testprof >/dev/null
}

teardown() {
	ubus call wrthotspot flush >/dev/null 2>&1
	/etc/init.d/wrthotspot stop
	nft delete table inet wrthotspot 2>/dev/null
	wrthotspot_users=/etc/wrthotspot/users.json
	rm -f "$wrthotspot_users" /tmp/wrthotspot/sessions.json
	cleanup
	/etc/init.d/network reload
	/etc/init.d/firewall reload >/dev/null 2>&1
}

if [ "$1" = cleanup ]; then
	teardown
	exit 0
fi

echo "== setup"
setup
check "hotspotd answers on ubus" ubus call wrthotspot status
check "dataplane table present" nft list table inet wrthotspot
check "client reaches the portal" page_has "$P/login" "Sign in"

echo "== unauthenticated"
check_not "IPv4 web blocked" online4
check_not "IPv6 web blocked" online6
check "IPv4 HTTP redirected to portal" redirected4
check "IPv6 HTTP redirected to portal" redirected6
check_not "IPv4 other port blocked" ccurl http://10.98.0.2:8080/
check_not "IPv6 ping blocked" C ping -6 -c1 -W1 fd98::2
check "RFC 8908 API says captive" page_has "$P/api/captive" '"captive": true'
check "host learned with IPv6 address" sh -c "wrthotspot hosts | grep 02:00:00:00:99:10 | grep -q fd99::"

echo "== bad login"
check "wrong password rejected" post_has 'username=alice&password=nope' 'invalid username or password'
check_not "still blocked after bad login" online4

echo "== PAP login"
check "PAP login accepted" post_has 'username=alice&password=secret&dst=http://10.98.0.2/' 'You are connected'
check "IPv4 web online" online4
check "IPv6 web online" online6
check "second IPv6 (privacy) address online without re-login" online6b
check "ping6 works" C ping -6 -c1 -W2 fd98::2
check "RFC 8908 API says not captive" page_has "$P/api/captive" '"captive": false'
ccurl -o /dev/null http://10.98.0.2/index.html
poll_wait
check "session accounted (bytes in > 0)" sh -c "ubus call wrthotspot sessions | jsonfilter -e '@.sessions[0].bytes_in' | grep -qv '^0$'"
check "status page renders" page_has "$P/status" alice

echo "== resilience"
/etc/init.d/wrthotspot restart
sleep 3
check "IPv4 survives daemon restart" online4
check "IPv6 survives daemon restart" online6
/etc/init.d/firewall reload >/dev/null 2>&1
sleep 1
check "survives fw4 reload" online4
nft delete table inet wrthotspot
poll_wait
check "table rebuilt after deletion" nft list table inet wrthotspot
check "session survives table deletion" online4

echo "== logout"
check "portal logout" sh -c "ip netns exec hsclient curl -s -m 5 -X POST $P/logout | grep -q 'logged out'"
check_not "IPv4 blocked again" online4
check_not "IPv6 blocked again" online6

echo "== CHAP login"
chap=$(ubus call wrthotspot client '{"ip":"10.99.0.10"}')
id=$(echo "$chap" | jsonfilter -e '@.chap_id_hex')
ch=$(echo "$chap" | jsonfilter -e '@.chap_challenge_hex')
hash=$(ucode -e "import { md5 } from 'digest'; print(md5(hexdec('$id') + 'secret' + hexdec('$ch')));")
check "CHAP login accepted" post_has "username=alice&password=$hash" 'You are connected'
check "online after CHAP" online4
wrthotspot logout alice >/dev/null
check_not "admin logout blocks" online4

echo "== limits"
post_has 'username=bob&password=bobpw' 'You are connected'
check "bob online" online4
sleep 6
poll_wait
check_not "bob logged out by uptime limit" online4
check "bob refused afterwards" post_has 'username=bob&password=bobpw' 'uptime limit reached'

echo "== trial"
check "trial login" page_has "$P/login?trial=yes" 'You are connected'
check "online on trial (IPv6)" online6
sleep 6
poll_wait
check_not "trial expired" online4
check "trial refused until reset" page_has "$P/login?trial=yes" 'free trial used up'

echo
echo "RESULT: $PASS passed, $FAIL failed"

[ "$1" = keep ] || teardown
[ "$FAIL" = 0 ]
