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
		rm -rf $BK
	fi

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
	I uhttpd -p 0.0.0.0:80 -p '[::]:80' -p 0.0.0.0:8081 -p '[::]:8081' -h /tmp/hsinet-www
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
check_not "carol idled out again" online4
C ping -c1 -W1 10.99.0.1 >/dev/null 2>&1
sleep 1
check "device back: logged in by MAC cookie, no page" online4
check "session shows mac-cookie login" sh -c "wrthotspot sessions | grep carol | grep -q mac-cookie"
wrthotspot logout carol >/dev/null
check_not "admin logout drops the MAC cookie" sh -c "wrthotspot cookies | grep mac | grep -q carol"

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
