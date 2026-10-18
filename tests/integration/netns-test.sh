#!/bin/sh
# End-to-end test on a real OpenWrt box (dedicated test device only!).
#
#  clients (netns)           router                          "internet" (netns hsinet)
#  hsclient  02:..:99:10 --+                                  10.98.0.2-.5  fd98::2-5
#  hsbypass  02:..:99:20 --+-- br-hstest 10.99.0.1 fd99::1    web servers on :80 and :8081
#  hsblocked 02:..:99:30 --+   [hotspot "hstest"]  hsi0p 10.98.0.1 fd98::1
#
# Needs ip-full, kmod-veth, curl (and dnsmasq-full + libustream-* for the
# nftset / HTTPS parts). The router's network/firewall/dhcp/wrthotspot configs
# are backed up first and restored afterwards.
#
# Usage: netns-test.sh [keep|cleanup]

PORT=8002
HTTPS_PORT=8003
P="http://10.99.0.1:$PORT"
PASS=0
FAIL=0
SKIP=0
BK=/tmp/hstest-backup
CONFIGS="network firewall dhcp wrthotspot"

C() { ip netns exec hsclient "$@"; }
I() { ip netns exec hsinet "$@"; }
ccurl() { C curl -s -m 5 "$@"; }

ok()   { PASS=$((PASS+1)); echo "  ok    $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
skip() { SKIP=$((SKIP+1)); echo "  skip  $*"; }
check()     { d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
check_not() { d=$1; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }

code_is() { [ "$(ccurl -o /dev/null -w '%{http_code}' "$@")" = 200 ]; }
ns_code_is() { ns=$1; shift; [ "$(ip netns exec "$ns" curl -s -m 5 -o /dev/null -w '%{http_code}' "$@")" = 200 ]; }
online4()  { code_is http://10.98.0.2/; }
online6()  { code_is 'http://[fd98::2]/'; }
online6b() { code_is --interface fd99::beef 'http://[fd98::2]/'; }
redirected4() { ccurl -o /dev/null -w '%{http_code} %{redirect_url}' http://10.98.0.2/x | grep -q "^302 $P/login?dst="; }
redirected6() { ccurl -o /dev/null -w '%{http_code} %{redirect_url}' 'http://[fd98::2]/x' | grep -q "^302 http://\[fd99::1\]:$PORT/login?dst="; }
page_has()  { ccurl "$1" | grep -q "$2"; }
post_has()  { ccurl -d "$1" "$P/login" | grep -q "$2"; }
poll_wait() { sleep 3; }
# hotspotd restarts dnsmasq when its snippet changes: wait until DNS answers.
wait_dns() { for i in 1 2 3 4 5 6 7 8 9 10; do nslookup wg.test 127.0.0.1 >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
reload_hs() { /etc/init.d/wrthotspot reload; sleep 3; wait_dns; }

add_client() {	# name mac ip4 ip6...
	ns=$1; mac=$2; ip4=$3; shift 3
	ip netns add "$ns"
	ip link add "${ns}0" type veth peer name "${ns}p"
	ip link set "${ns}0" netns "$ns"
	ip netns exec "$ns" ip link set lo up
	# Fixed addresses only: no SLAAC from the hotspot's RAs.
	ip netns exec "$ns" sysctl -qw net.ipv6.conf.default.accept_ra=0 net.ipv6.conf.all.accept_ra=0 "net.ipv6.conf.${ns}0.accept_ra=0"
	ip netns exec "$ns" ip link set "${ns}0" address "$mac" up
	ip netns exec "$ns" ip addr add "$ip4/24" dev "${ns}0"
	ip netns exec "$ns" ip route add default via 10.99.0.1
	for a in "$@"; do ip netns exec "$ns" ip -6 addr add "$a/64" dev "${ns}0" nodad; done
	ip netns exec "$ns" ip -6 route add default via fd99::1
	uci add_list network.br_hstest.ports="${ns}p"
	mkdir -p "/etc/netns/$ns"
	echo "nameserver 10.99.0.1" > "/etc/netns/$ns/resolv.conf"
}

cleanup() {
	for ns in hsclient hsbypass hsblocked hsinet; do
		ip netns pids $ns 2>/dev/null | xargs -r kill 2>/dev/null
		ip netns del $ns 2>/dev/null
		ip link del ${ns}p 2>/dev/null
		rm -rf /etc/netns/$ns
	done
	ip link del hsi0p 2>/dev/null
	for f in /tmp/dnsmasq*.d/hstest.conf; do rm -f "$f"; done
	if [ -d $BK ]; then
		for c in $CONFIGS; do cp $BK/$c /etc/config/$c; done
		[ -f $BK/fr-dictionary ] && cp $BK/fr-dictionary /etc/freeradius3/dictionary
		[ -f $BK/fr-authorize ] && cp $BK/fr-authorize /etc/freeradius3/mods-config/files/authorize
		rm -rf $BK
	fi
	[ -x /etc/init.d/radiusd ] && /etc/init.d/radiusd stop 2>/dev/null
	rm -f /tmp/hsinet-www/big.bin

	# Belt and braces: nothing of the test topology may survive into the next
	# run's backup (sections referencing hstest/hsinet, by name or by value).
	for c in network firewall dhcp wrthotspot; do
		# Reverse order: deleting @type[N] shifts the indexes of later sections.
		for s in $(uci -q show $c | grep -E "hstest|hsinet|br_hstest|Allow-hstest" | sed -n "s/^$c\.\([^.=]*\).*/\1/p" | sort -u | sort -t[ -k2 -rn); do
			uci -q delete "$c.$s"
		done
		uci commit $c
	done
}

teardown() {
	ubus call wrthotspot flush >/dev/null 2>&1
	/etc/init.d/wrthotspot stop
	nft delete table inet wrthotspot 2>/dev/null
	rm -f /etc/wrthotspot/users.json /etc/wrthotspot/cookies.json /etc/wrthotspot/portal.* /tmp/wrthotspot/sessions.json
	cleanup
	/etc/init.d/network reload
	/etc/init.d/firewall reload >/dev/null 2>&1
	/etc/init.d/dnsmasq restart
	/etc/init.d/odhcpd restart
}

setup() {
	# Start from a clean daemon state: no sessions, users or cookies of an
	# earlier (kept) run may leak into this one.
	ubus call wrthotspot flush >/dev/null 2>&1
	/etc/init.d/wrthotspot stop
	rm -f /etc/wrthotspot/users.json /etc/wrthotspot/cookies.json /tmp/wrthotspot/sessions.json
	cleanup
	mkdir -p $BK
	for c in $CONFIGS; do cp /etc/config/$c $BK/$c; done
	# Always start from the package's default hotspot config.
	cp "$(dirname "$0")/../../feed/net/wrt-hotspot/files/etc/config/wrthotspot" /etc/config/wrthotspot

	uci set network.br_hstest=device
	uci set network.br_hstest.type=bridge
	uci set network.br_hstest.name=br-hstest
	add_client hsclient 02:00:00:00:99:10 10.99.0.10 fd99::10 fd99::beef
	add_client hsbypass 02:00:00:00:99:20 10.99.0.20 fd99::20
	add_client hsblocked 02:00:00:00:99:30 10.99.0.30 fd99::30

	ip netns add hsinet
	ip link add hsi0 type veth peer name hsi0p
	ip link set hsi0 netns hsinet
	I ip link set lo up
	I ip link set hsi0 up
	for n in 2 3 4 5; do
		I ip addr add 10.98.0.$n/24 dev hsi0
		I ip -6 addr add fd98::$n/64 dev hsi0 nodad
	done
	I ip route add default via 10.98.0.1
	I ip -6 route add default via fd98::1
	mkdir -p /tmp/hsinet-www
	echo "hello from the internet" > /tmp/hsinet-www/index.html
	dd if=/dev/zero of=/tmp/hsinet-www/big.bin bs=1k count=200 2>/dev/null
	I uhttpd -p 0.0.0.0:80 -p '[::]:80' -p 0.0.0.0:8081 -p '[::]:8081' -h /tmp/hsinet-www
	command -v iperf3 >/dev/null && I iperf3 -s -D
	# An upstream DNS server for wg.test, so answers reach the router's
	# dnsmasq as forwarded replies (nftset= ignores its own address= records).
	I dnsmasq --conf-file=/dev/null --port=53 --listen-address=10.98.0.2 --bind-interfaces \
		--no-resolv --no-hosts --pid-file=/tmp/hsinet-dns.pid \
		--address=/wg.test/10.98.0.4 --address=/wg.test/fd98::4 \
		--address=/sub.wg.test/10.98.0.5 --address=/sub.wg.test/fd98::5

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
	uci set firewall.$z.input=ACCEPT	# simulated internet: let its ICMPv6 ND reach us
	uci set firewall.$z.output=ACCEPT
	uci set firewall.$z.forward=REJECT
	uci commit firewall

	wrthotspot setup hstest >/dev/null
	f=$(uci add firewall forwarding)
	uci set firewall.$f.src=hstest
	uci set firewall.$f.dest=hsinet
	uci commit firewall

	# Forward the test domain upstream (private answers allowed for it).
	for d in /tmp/dnsmasq*.d; do
		printf 'server=/wg.test/10.98.0.2\nrebind-domain-ok=/wg.test/\n' > "$d/hstest.conf"
	done

	uci set wrthotspot.global.poll_interval=2s
	uci set wrthotspot.testprof=user_profile
	uci set wrthotspot.testprof.shared_users=1
	uci set wrthotspot.testprof.keepalive_timeout=0
	uci set wrthotspot.testprof.add_mac_cookie=0
	uci set wrthotspot.idleprof=user_profile
	uci set wrthotspot.idleprof.idle_timeout=4s
	uci set wrthotspot.idleprof.keepalive_timeout=0
	uci set wrthotspot.idleprof.mac_cookie_timeout=1h
	uci add_list wrthotspot.@server_profile[0].login_by=trial
	uci set wrthotspot.@server_profile[0].trial_uptime_limit=6s

	uci set wrthotspot.wg_ip=walled_garden
	uci set wrthotspot.wg_ip.dst_address='10.98.0.3 fd98::3'
	uci set wrthotspot.wg_port=walled_garden
	uci set wrthotspot.wg_port.dst_port=8081
	uci set wrthotspot.wg_deny=walled_garden
	uci set wrthotspot.wg_deny.dst_address=10.98.0.2
	uci set wrthotspot.wg_deny.dst_port=8081
	uci set wrthotspot.wg_deny.action=deny
	uci set wrthotspot.wg_host=walled_garden
	uci set wrthotspot.wg_host.dst_host='*.wg.test'

	uci set wrthotspot.bp=ip_binding
	uci set wrthotspot.bp.mac=02:00:00:00:99:20
	uci set wrthotspot.bp.type=bypassed
	uci set wrthotspot.bl=ip_binding
	uci set wrthotspot.bl.address=10.99.0.30
	uci set wrthotspot.bl.type=blocked
	uci set wrthotspot.bl6=ip_binding
	uci set wrthotspot.bl6.address=fd99::30
	uci set wrthotspot.bl6.type=blocked
	uci commit wrthotspot

	/etc/init.d/network reload
	sleep 5
	/etc/init.d/firewall reload >/dev/null 2>&1
	/etc/init.d/dnsmasq restart
	/etc/init.d/wrthotspot enable
	/etc/init.d/wrthotspot restart
	sleep 4
	wait_dns
	wrthotspot user add alice password=secret profile=testprof >/dev/null
	wrthotspot user add bob password=bobpw limit_uptime=5s profile=testprof >/dev/null
	wrthotspot user add carol password=carolpw profile=idleprof >/dev/null
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
check_not "IPv4 other port blocked" ccurl http://10.98.0.2:9/
check_not "IPv6 ping blocked" C ping -6 -c1 -W1 fd98::2
check "RFC 8908 API says captive" page_has "$P/api/captive" '"captive": true'
check "host learned with IPv6 address" sh -c "wrthotspot hosts | grep 02:00:00:00:99:10 | grep -q fd99::"
check "Android probe redirected (captive)" sh -c "ip netns exec hsclient curl -s -m5 -o /dev/null -w '%{http_code}' http://10.98.0.2/generate_204 | grep -q 302"
check "DNS hijacked to router (v4)" sh -c "ip netns exec hsclient nslookup wg.test 10.98.0.2 | grep -q 10.98.0.4"
check "DNS hijacked to router (v6)" sh -c "ip netns exec hsclient nslookup wg.test fd98::2 | grep -q 10.98.0.4"

echo "== walled garden"
check "IP entry reachable (v4)" code_is http://10.98.0.3/
check "IP entry reachable (v6)" code_is 'http://[fd98::3]/'
check "port entry reachable (v4)" code_is http://10.98.0.4:8081/
check "port entry reachable (v6)" code_is 'http://[fd98::5]:8081/'
check_not "deny entry carves out exception" code_is http://10.98.0.2:8081/
check "host entry resolved by hotspotd (v4)" code_is http://10.98.0.4/
check "host entry resolved by hotspotd (v6)" code_is 'http://[fd98::4]/'
if dnsmasq -v | grep -q ' nftset'; then
	check_not "subdomain not open before lookup" code_is http://10.98.0.5/
	C nslookup sub.wg.test >/dev/null 2>&1
	check "subdomain open after DNS lookup (dnsmasq nftset)" code_is http://10.98.0.5/
	C nslookup -type=aaaa sub.wg.test >/dev/null 2>&1
	check "subdomain open after DNS lookup, IPv6" code_is 'http://[fd98::5]/'
else
	skip "subdomain via dnsmasq nftset (stock dnsmasq has no nftset)"
fi

echo "== ip bindings"
check "bypassed MAC online without login (v4)" ns_code_is hsbypass http://10.98.0.2/
check "bypassed MAC online without login (v6)" ns_code_is hsbypass 'http://[fd98::2]/'
check_not "blocked host cannot browse" ns_code_is hsblocked http://10.98.0.2/
check_not "blocked host cannot reach portal" ns_code_is hsblocked "$P/login"
check_not "blocked host cannot reach portal over IPv6" ns_code_is hsblocked "http://[fd99::1]:$PORT/login"

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
check "Apple probe answered Success via stale NAT" sh -c "ip netns exec hsclient curl -s -m5 -H 'Host: captive.apple.com' $P/hotspot-detect.html | grep -q Success"
check "Android probe answered 204 via stale NAT" sh -c "ip netns exec hsclient curl -s -m5 -o /dev/null -w '%{http_code}' -H 'Host: connectivitycheck.gstatic.com' $P/generate_204 | grep -q 204"
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
sleep 2
check "table rebuilt after deletion" nft list table inet wrthotspot
check "session survives table deletion" online4
check "walled garden host refilled after rebuild" sh -c "nft list set inet wrthotspot wgh4_4 | grep -q 10.98.0.4"

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

echo "== HTTP cookie"
rm -f /tmp/hstest.jar
C curl -s -m5 -c /tmp/hstest.jar -d 'username=carol&password=carolpw' "$P/login" >/dev/null
check "cookie issued on login" grep -q wrthotspot /tmp/hstest.jar
token=$(awk '/wrthotspot/ { print $7 }' /tmp/hstest.jar)
sleep 5
poll_wait
check_not "carol idled out" online4
check "cookie kept after idle-timeout" sh -c "wrthotspot cookies | grep -q carol"
check "cookie logs back in without password" sh -c "ip netns exec hsclient curl -s -m5 -b 'wrthotspot=$token' $P/login | grep -q 'You are connected'"
check "online after cookie login" online4
C curl -s -m5 -b "wrthotspot=$token" -X POST "$P/logout" >/dev/null
check_not "explicit logout drops the cookie" sh -c "wrthotspot cookies | grep -q carol"
check "stale cookie no longer logs in" sh -c "ip netns exec hsclient curl -s -m5 -b 'wrthotspot=$token' $P/login | grep -q 'Sign in'"

echo "== MAC cookie"
uci add_list wrthotspot.@server_profile[0].login_by=mac-cookie
uci commit wrthotspot
reload_hs
post_has 'username=carol&password=carolpw' 'You are connected'
check "MAC cookie stored" sh -c "wrthotspot cookies | grep mac | grep -q carol"
sleep 5
poll_wait
# Browsing would bring the device back (and the MAC cookie logs it in), so
# check the logout in the session history instead.
check "carol idled out again" sh -c "ubus call wrthotspot history '{\"search\":\"carol\",\"limit\":1}' | jsonfilter -e '@.history[0].cause' | grep -qx idle-timeout"
# A returning device probes connectivity (the portal sees it and the MAC
# cookie logs it in), like phones do when they rejoin.
C curl -s -m 3 -o /dev/null http://10.98.0.2/generate_204
sleep 1
check "device back: logged in by MAC cookie, no page" online4
check "session shows mac-cookie login" sh -c "wrthotspot sessions | grep carol | grep -q mac-cookie"
wrthotspot logout carol >/dev/null
check_not "admin logout drops the MAC cookie" sh -c "wrthotspot cookies | grep mac | grep -q carol"

echo "== rate limits"
# Mbit/s measured by iperf3 from the client (-R = download, -O = skip TCP ramp-up).
# Steady-state TCP goodput through HTB is ~95% of the rate (header overhead).
mbps() { C iperf3 -c "$@" -J 2>/dev/null | jsonfilter -e '@.end.sum_received.bits_per_second' | awk '{ printf "%.2f", $1 / 1000000 }'; }
between() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; }
check_rate() { d=$1; v=$2; lo=$3; hi=$4; if between "$v" "$lo" "$hi"; then ok "$d ($v Mbit/s)"; else bad "$d ($v Mbit/s, want $lo-$hi)"; fi; }

if command -v iperf3 >/dev/null && command -v tc >/dev/null; then
	uci set wrthotspot.rateprof=user_profile
	uci set wrthotspot.rateprof.rate_limit='1M/4M'
	uci set wrthotspot.rateprof.keepalive_timeout=0
	uci set wrthotspot.burstprof=user_profile
	uci set wrthotspot.burstprof.rate_limit='1M/1M 4M/4M 768k/768k 8/8'
	uci set wrthotspot.burstprof.keepalive_timeout=0
	uci commit wrthotspot
	reload_hs
	wrthotspot user add rate1 password=x profile=rateprof >/dev/null
	wrthotspot user add burst1 password=x profile=burstprof >/dev/null

	check "tc HTB tree on the hotspot device" sh -c "tc qdisc show dev br-hstest | grep -q 'htb 1:' && tc filter show dev br-hstest ingress | grep -q hsifb"
	post_has 'username=rate1&password=x' 'You are connected'
	check "per-session class created" sh -c "tc class show dev br-hstest | grep -q 'ceil 4Mbit'"
	check_rate "download limited to 4M (IPv4)" "$(mbps 10.98.0.2 -R -t 10 -O 3)" 3.6 4.05
	check_rate "download limited to 4M (IPv6)" "$(mbps fd98::2 -R -t 10 -O 3)" 3.6 4.05
	check_rate "upload limited to 1M" "$(mbps 10.98.0.2 -t 10 -O 3)" 0.9 1.08
	wrthotspot logout rate1 >/dev/null
	check_not "class removed on logout" sh -c "tc class show dev br-hstest | grep -q 'ceil 4Mbit'"
	post_has 'username=alice&password=secret' 'You are connected'
	v=$(mbps 10.98.0.2 -R -t 3)
	if awk -v v="$v" 'BEGIN { exit !(v > 20) }'; then ok "user without rate limit is unshaped ($v Mbit/s)"; else bad "user without rate limit is unshaped ($v Mbit/s)"; fi
	wrthotspot logout alice >/dev/null

	post_has 'username=burst1&password=x' 'You are connected'
	C iperf3 -c 10.98.0.2 -R -t 12 -i 1 -J 2>/dev/null > /tmp/hstest-burst.json
	first=$(jsonfilter -i /tmp/hstest-burst.json -e '@.intervals[0].sum.bits_per_second' | awk '{ printf "%.2f", $1 / 1000000 }')
	late=$(jsonfilter -i /tmp/hstest-burst.json -e '@.intervals[*].sum.bits_per_second' | tail -6 | awk '{ s += $1 } END { printf "%.2f", s / NR / 1000000 }')
	check_rate "burst: first second at burst rate" "$first" 2.5 4.6
	check_rate "burst: back to max-limit once the average passes the threshold" "$late" 0.6 1.4
	rm -f /tmp/hstest-burst.json
	wrthotspot logout burst1 >/dev/null

	uci set wrthotspot.global.shaper=nft
	uci commit wrthotspot
	/etc/init.d/wrthotspot restart
	sleep 4
	wait_dns
	check_not "nft backend: no tc tree" sh -c "tc qdisc show dev br-hstest | grep -q 'htb 1:'"
	post_has 'username=rate1&password=x' 'You are connected'
	check "nft backend: policers in the table" sh -c "nft list map inet wrthotspot lim_down | grep -q ld_"
	check_rate "nft backend: download policed near 4M" "$(mbps 10.98.0.2 -R -t 10 -O 3)" 3.0 4.4
	wrthotspot logout rate1 >/dev/null
	check_not "nft backend: policer removed on logout" sh -c "nft list map inet wrthotspot lim_down | grep -q ld_"
	uci set wrthotspot.global.shaper=auto
	uci commit wrthotspot
	/etc/init.d/wrthotspot restart
	sleep 4
	wait_dns
else
	skip "rate limit tests (need iperf3 and tc)"
fi

echo "== scheduled limitations"
now=$(date +%s)
hm() { date -d "@$1" +%H:%M; }
uci set wrthotspot.open_now=limitation
uci set wrthotspot.open_now.from_time="$(hm $((now - 3600)))"
uci set wrthotspot.open_now.till_time="$(hm $((now + 600)))"
uci set wrthotspot.open_now.rate_limit='512k/512k'
uci set wrthotspot.open_now.transfer_limit=1M
uci set wrthotspot.open_now.reset=daily
uci set wrthotspot.closed_now=limitation
uci set wrthotspot.closed_now.from_time="$(hm $((now + 7200)))"
uci set wrthotspot.closed_now.till_time="$(hm $((now + 10800)))"
uci set wrthotspot.schedprof=user_profile
uci add_list wrthotspot.schedprof.limitation=open_now
uci set wrthotspot.schedprof.keepalive_timeout=0
uci set wrthotspot.nightprof=user_profile
uci add_list wrthotspot.nightprof.limitation=closed_now
uci commit wrthotspot
reload_hs
wrthotspot user add sched1 password=x profile=schedprof >/dev/null
wrthotspot user add night1 password=x profile=nightprof >/dev/null

check "login refused outside the window" post_has 'username=night1&password=x' 'access is not allowed at this time'
check "login inside the window" post_has 'username=sched1&password=x' 'You are connected'
check "session ends with the window (<= 10 min)" sh -c "t=\$(ubus call wrthotspot sessions | jsonfilter -e \"@.sessions[@.user='sched1'].limits.max_uptime\"); [ \$t -gt 0 ] && [ \$t -le 600 ]"
check "limitation rate limit in force" sh -c "[ \"\$(ubus call wrthotspot sessions | jsonfilter -e \"@.sessions[@.user='sched1'].rate_limit\")\" = 512k/512k ]"
command -v iperf3 >/dev/null && check_rate "limitation rate measured" "$(mbps 10.98.0.2 -R -t 10 -O 3)" 0.45 0.55
for i in 1 2 3 4 5 6; do ccurl -o /dev/null http://10.98.0.2/big.bin; done
poll_wait
check_not "period quota ends the session" online4
check "quota refused for the rest of the period" post_has 'username=sched1&password=x' 'traffic limit reached for this period'
check "period usage stored" sh -c "grep -q open_now /etc/wrthotspot/users.json || (ubus call wrthotspot user_get '{\"name\":\"sched1\"}' | grep -q open_now)"
wrthotspot user reset sched1 >/dev/null
check "counter reset clears the period quota" post_has 'username=sched1&password=x' 'You are connected'
wrthotspot logout sched1 >/dev/null

echo "== RADIUS (FreeRADIUS on the router)"
if command -v radiusd >/dev/null; then
	RD=/etc/freeradius3
	ACCT=/var/db/radacct/127.0.0.1
	cp $RD/dictionary $BK/fr-dictionary
	cp $RD/mods-config/files/authorize $BK/fr-authorize
	cat >> $RD/dictionary <<'EOF'
VENDOR		Mikrotik			14988
BEGIN-VENDOR	Mikrotik
ATTRIBUTE	Mikrotik-Recv-Limit		1	integer
ATTRIBUTE	Mikrotik-Xmit-Limit		2	integer
ATTRIBUTE	Mikrotik-Group			3	string
ATTRIBUTE	Mikrotik-Rate-Limit		8	string
ATTRIBUTE	Mikrotik-Recv-Limit-Gigawords	14	integer
ATTRIBUTE	Mikrotik-Xmit-Limit-Gigawords	15	integer
ATTRIBUTE	Mikrotik-Total-Limit		17	integer
ATTRIBUTE	Mikrotik-Total-Limit-Gigawords	18	integer
ATTRIBUTE	Mikrotik-Address-List		19	string
END-VENDOR	Mikrotik
EOF
	soon=$(date -u -d @$(( $(date +%s) + 25 )) +%Y-%m-%dT%H:%M:%SZ)
	{ cat <<EOF
radalice Cleartext-Password := "radpw"
	Reply-Message = "Welcome radalice",
	Session-Timeout = 3600,
	Acct-Interim-Interval = 10,
	Class = "gold-plan",
	Mikrotik-Rate-Limit = "2M/4M"
radshort Cleartext-Password := "x"
	Session-Timeout = 5
radquota Cleartext-Password := "x"
	Mikrotik-Xmit-Limit = 30000
radgroup Cleartext-Password := "x"
	Mikrotik-Group = "idleprof"
radwispr Cleartext-Password := "x"
	WISPr-Session-Terminate-Time = "$soon"
radbad Auth-Type := Reject
	Reply-Message = "Account suspended"
"02:00:00:00:99:10" Cleartext-Password := "macsecret"
	Session-Timeout = 600
EOF
	cat $BK/fr-authorize; } > $RD/mods-config/files/authorize
	rm -rf /var/db/radacct
	dd if=/dev/zero of=/tmp/hsinet-www/big.bin bs=1k count=200 2>/dev/null
	/etc/init.d/radiusd restart
	sleep 3

	uci set wrthotspot.rad=radius
	uci set wrthotspot.rad.address=127.0.0.1
	uci set wrthotspot.rad.secret=testing123
	uci set wrthotspot.@server_profile[0].use_radius=1
	uci commit wrthotspot
	reload_hs
	wrthotspot logout 02:00:00:00:99:10 >/dev/null 2>&1
	sid() { ubus call wrthotspot sessions | jsonfilter -e "@.sessions[@.user='$1'].id"; }
	sess() { ubus call wrthotspot sessions | jsonfilter -e "@.sessions[@.user='$1'].$2"; }
	detail() { cat $ACCT/detail-* 2>/dev/null; }

	check "CoA listener on 3799" sh -c "netstat -lnu | grep -q ':3799 '"
	check "RADIUS PAP login" post_has 'username=radalice&password=radpw' 'You are connected'
	check "online via RADIUS user" online4
	check "session marked radius, rate limit from Mikrotik-Rate-Limit" sh -c "[ \"\$(ubus call wrthotspot sessions | jsonfilter -e \"@.sessions[@.user='radalice'].rate_limit\")\" = 2M/4M ]"
	check "Session-Timeout applied" sh -c "[ \"\$(ubus call wrthotspot sessions | jsonfilter -e \"@.sessions[@.user='radalice'].limits.max_uptime\")\" = 3600 ]"
	sleep 1
	check "Accounting-Start received" sh -c "cat $ACCT/detail-* | grep -q 'Acct-Status-Type = Start'"
	check "Start carries Class + Calling-Station-Id + IPv6" sh -c "cat $ACCT/detail-* | grep -q 'Class = 0x676f6c642d706c616e' && cat $ACCT/detail-* | grep -q 'Calling-Station-Id = \"02:00:00:00:99:10\"' && cat $ACCT/detail-* | grep -q 'Framed-IPv6-Address = fd99'"
	ccurl -o /dev/null http://10.98.0.2/big.bin
	sleep 12
	poll_wait
	check "Interim-Update with traffic" sh -c "cat $ACCT/detail-* | grep -A30 'Interim-Update' | grep -E 'Acct-Output-Octets = [0-9]{6,}' -q"
	check "Interim carries gigawords" sh -c "cat $ACCT/detail-* | grep -q 'Acct-Output-Gigawords = 0'"
	s=$(sid radalice)
	out=$(printf 'Acct-Session-Id = "%s"\nMessage-Authenticator = 0x00\n' "$s" | radclient -r1 -t3 127.0.0.1:3799 disconnect testing123 2>&1)
	check "Disconnect-Request acknowledged" sh -c "echo '$out' | grep -q 'Disconnect-ACK'"
	check_not "offline after Disconnect" online4
	check "Stop with Admin-Reset" sh -c "cat $ACCT/detail-* | grep -B30 'Acct-Terminate-Cause = Admin-Reset' | grep -q radalice"
	out=$(printf 'Acct-Session-Id = "deadbeef"\nMessage-Authenticator = 0x00\n' | radclient -r1 -t3 127.0.0.1:3799 disconnect testing123 2>&1)
	check "Disconnect for unknown session NAKed" sh -c "echo '$out' | grep -q 'Disconnect-NAK'"
	out=$(printf 'User-Name = "nobody"\n' | radclient -r1 -t3 127.0.0.1:3799 disconnect testing123 2>&1)
	check_not "Disconnect without Message-Authenticator ignored" sh -c "echo '$out' | grep -qE 'Disconnect-(ACK|NAK)'"

	post_has 'username=radalice&password=radpw' 'You are connected'
	out=$(printf 'User-Name = "radalice"\nSession-Timeout = 4\nMikrotik-Rate-Limit = "1M/1M"\nMessage-Authenticator = 0x00\n' | radclient -r1 -t3 127.0.0.1:3799 coa testing123 2>&1)
	check "CoA acknowledged" sh -c "echo '$out' | grep -q 'CoA-ACK'"
	command -v tc >/dev/null && check "CoA rate applied to the tc class" sh -c "sleep 3; tc class show dev br-hstest | grep -q 'ceil 1Mbit'"
	check "CoA changed the rate limit" sh -c "[ \"\$(ubus call wrthotspot sessions | jsonfilter -e \"@.sessions[@.user='radalice'].rate_limit\")\" = 1M/1M ]"
	sleep 4
	poll_wait
	check_not "CoA Session-Timeout ended the session" online4

	chap=$(ubus call wrthotspot client '{"ip":"10.99.0.10"}')
	id=$(echo "$chap" | jsonfilter -e '@.chap_id_hex')
	ch=$(echo "$chap" | jsonfilter -e '@.chap_challenge_hex')
	hash=$(ucode -e "import { md5 } from 'digest'; print(md5(hexdec('$id') + 'radpw' + hexdec('$ch')));")
	check "RADIUS CHAP login" post_has "username=radalice&password=$hash" 'You are connected'
	wrthotspot logout radalice >/dev/null

	check "Access-Reject shows Reply-Message" post_has 'username=radbad&password=x' 'Account suspended'
	check "unknown RADIUS user rejected" post_has 'username=nosuchuser&password=x' 'invalid username or password'
	check_not "still offline after rejects" online4

	post_has 'username=radshort&password=x' 'You are connected'
	sleep 6
	poll_wait
	check_not "RADIUS Session-Timeout logs out" online4
	check "Stop with Session-Timeout" sh -c "cat $ACCT/detail-* | grep -A40 'User-Name = \"radshort\"' | grep -q 'Acct-Terminate-Cause = Session-Timeout'"

	post_has 'username=radquota&password=x' 'You are connected'
	ccurl -o /dev/null http://10.98.0.2/big.bin
	poll_wait
	check_not "Mikrotik-Xmit-Limit enforced" online4
	check "Stop with NAS-Request for traffic limit" sh -c "cat $ACCT/detail-* | grep -A40 'User-Name = \"radquota\"' | grep -q 'Acct-Terminate-Cause = NAS-Request'"

	post_has 'username=radgroup&password=x' 'You are connected'
	check "Mikrotik-Group selects user profile" sh -c "[ \"\$(ubus call wrthotspot sessions | jsonfilter -e \"@.sessions[@.user='radgroup'].profile\")\" = idleprof ]"
	wrthotspot logout radgroup >/dev/null

	post_has 'username=radwispr&password=x' 'You are connected'
	check "WISPr-Session-Terminate-Time applied" sh -c "t=\$(ubus call wrthotspot sessions | jsonfilter -e \"@.sessions[@.user='radwispr'].limits.max_uptime\"); [ \$t -gt 0 ] && [ \$t -le 26 ]"
	wrthotspot logout radwispr >/dev/null

	wrthotspot cookie del 02:00:00:00:99:10 >/dev/null
	uci set wrthotspot.@server_profile[0].mac_auth_password=macsecret
	uci add_list wrthotspot.@server_profile[0].login_by=mac
	uci commit wrthotspot
	reload_hs
	C ping -c1 -W1 10.99.0.1 >/dev/null 2>&1
	sleep 2
	check "MAC authentication via RADIUS (no page)" online4
	check "session shows login by mac" sh -c "wrthotspot sessions | grep '02:00:00:00:99:10' | grep -q ' mac '"
	uci del_list wrthotspot.@server_profile[0].login_by=mac
	uci set wrthotspot.@server_profile[0].use_radius=0
	uci commit wrthotspot
	reload_hs
	wrthotspot logout 02:00:00:00:99:10 >/dev/null
	/etc/init.d/radiusd stop
else
	skip "RADIUS tests (freeradius3 not installed)"
fi

echo "== HTTPS login + RFC 8910"
if ls /lib/libustream-ssl.so* >/dev/null 2>&1; then
	wrthotspot cert login.wifi >/dev/null
	uci set wrthotspot.@server_profile[0].dns_name=login.wifi
	uci add_list wrthotspot.@server_profile[0].login_by=https
	uci commit wrthotspot
	reload_hs
	H="https://login.wifi:$HTTPS_PORT"
	check "uhttpd listens for HTTPS" sh -c "netstat -ltn | grep -q ':$HTTPS_PORT '"
	check "portal name resolves to router (A)" sh -c "ip netns exec hsclient nslookup login.wifi | grep -q 10.99.0.1"
	check "portal name resolves to router (AAAA)" sh -c "ip netns exec hsclient nslookup -type=aaaa login.wifi | grep -q fd99::1"
	check "redirect now goes to HTTPS login" sh -c "ip netns exec hsclient curl -s -m5 -o /dev/null -w '%{redirect_url}' http://10.98.0.2/ | grep -q '^$H/login'"
	check "HTTP login page redirects to HTTPS" sh -c "ip netns exec hsclient curl -s -m5 -o /dev/null -w '%{redirect_url}' http://login.wifi:$PORT/login | grep -q '^$H/login'"
	check "HTTPS login page served" sh -c "ip netns exec hsclient curl -k -s -m5 $H/login | grep -q 'Sign in'"
	check_not "no CHAP over HTTPS" sh -c "ip netns exec hsclient curl -k -s -m5 $H/login | grep -q onsubmit"
	check "HTTPS API says captive" sh -c "ip netns exec hsclient curl -k -s -m5 $H/api/captive | grep -q '\"captive\": true'"
	check "HTTPS PAP login" sh -c "ip netns exec hsclient curl -k -s -m5 -d 'username=alice&password=secret' $H/login | grep -q 'You are connected'"
	check "online after HTTPS login (v6)" online6
	check "dnsmasq announces RFC 8910 option 114" sh -c "grep -q '114,\"$H/api/captive\"' /tmp/dnsmasq*.d/wrthotspot.conf"
	check "odhcpd configured with captive_portal_uri" sh -c "uci -q get dhcp.hstest.captive_portal_uri | grep -q '$H/api/captive'"
	printf '#!/bin/sh\nenv > /tmp/hstest-dhcp.env\n' > /tmp/hstest-udhcpc.sh
	chmod +x /tmp/hstest-udhcpc.sh
	C udhcpc -i hsclient0 -n -q -f -t 3 -O 114 -s /tmp/hstest-udhcpc.sh >/dev/null 2>&1
	check "DHCP client receives option 114" grep -qi 'opt114=' /tmp/hstest-dhcp.env
	rm -f /tmp/hstest-udhcpc.sh /tmp/hstest-dhcp.env
else
	skip "HTTPS tests (no libustream TLS library)"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"

[ "$1" = keep ] || teardown
[ "$FAIL" = 0 ]
