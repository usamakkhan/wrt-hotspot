#!/bin/sh
# Regression checks for bugs found in the 0.8.0 code review. Run on the test
# router after `netns-test.sh keep` (client namespace hsclient, server hstest).
# (Checks call shell functions directly: functions do not exist in `sh -c`.)

P="http://10.99.0.1:8002"
PASS=0; FAIL=0
C() { ip netns exec hsclient "$@"; }
ccurl() { C curl -s -m 5 "$@"; }
ok()   { PASS=$((PASS+1)); echo "  ok    $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
check()     { d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
check_not() { d=$1; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
online4() { [ "$(ccurl -o /dev/null -w '%{http_code}' http://10.98.0.2/)" = 200 ]; }
hs() { ubus call wrthotspot "$@"; }
daemon_pid() { pgrep -f 'ucode -S /usr/sbin/hotspotd' | head -1; }
reload_hs() { /etc/init.d/wrthotspot reload; sleep 3; }
# The daemon publishes its ubus object once the dataplane is built: wait for
# that (slow routers need well over 3 s) instead of a fixed sleep.
restart_hs() {
	/etc/init.d/wrthotspot restart
	for i in $(seq 1 30); do ubus -t 2 call wrthotspot status >/dev/null 2>&1 && break; sleep 1; done
	sleep 1
}
logout_client() { wrthotspot logout 02:00:00:00:99:10 >/dev/null 2>&1; }
login() { ccurl -d "username=$1&password=$2&dst=http://10.98.0.2/" $P/login | grep -q 'You are connected'; }

# Plain HTTP PAP for these checks (the kept topology may demand HTTPS).
uci -q del_list wrthotspot.@server_profile[0].login_by=https
uci -q set wrthotspot.@server_profile[0].use_radius=0
uci commit wrthotspot
reload_hs
logout_client
wrthotspot cookie del 02:00:00:00:99:10 >/dev/null 2>&1
wrthotspot user add regr password=pw1 >/dev/null

echo "== core without wrt-hotspot-radius"
mv /usr/share/ucode/wrthotspot/radius.uc /tmp/radius.uc.regr
restart_hs
pid=$(daemon_pid)
check "local login works without RADIUS" login regr pw1
check "online" online4
logout_client; sleep 1
check_not "logout works without RADIUS" online4
same_pid() { [ "$(daemon_pid)" = "$pid" ]; }
check "daemon survived login and logout" same_pid
mv /tmp/radius.uc.regr /usr/share/ucode/wrthotspot/radius.uc
restart_hs

echo "== tc: first shaped session after a start is not the root class"
if command -v tc >/dev/null; then
	uci set wrthotspot.regrprof=user_profile; uci set wrthotspot.regrprof.name=regrprof; uci set wrthotspot.regrprof.rate_limit=1M/2M
	uci commit wrthotspot
	wrthotspot user set regr profile=regrprof >/dev/null
	restart_hs
	login regr pw1
	sleep 2
	root_full() { tc class show dev br-hstest | grep 'class htb 1:1 root' | grep -qv 'ceil 2Mbit'; }
	session_class() { tc class show dev br-hstest | grep -v 'class htb 1:1 ' | grep -q 'ceil 2Mbit'; }
	default_leaf() { tc qdisc show dev br-hstest | grep -q 'fq_codel fffe:'; }
	check "root class 1:1 keeps the full capacity" root_full
	check "session class has the user's rate" session_class
	check "default leaf has its own handle fffe:" default_leaf
	logout_client
	wrthotspot user set regr profile=default >/dev/null
	uci -q delete wrthotspot.regrprof; uci commit wrthotspot; reload_hs
fi

echo "== portal"
login regr pw1
injected() { ccurl -D - -o /dev/null "$P/login?dst=http://x%0d%0aX-Injected:%20yes" | grep -qi '^X-Injected'; }
js_link() { ccurl "$P/login?dst=javascript:alert(1)" | grep -q 'javascript:alert'; }
http_dst() { ccurl -o /dev/null -w '%{redirect_url}' "$P/login?dst=http://10.98.0.2/" | grep -q '^http://10.98.0.2/'; }
check_not "CR/LF in dst cannot add a header" injected
check_not "javascript: dst is not used as the link" js_link
check "http dst still redirects" http_dst
ccurl -H 'Referer: http://evil.example/' $P/logout >/dev/null; sleep 1
check "cross-site GET /logout keeps the session" online4
same_site_logout() { ccurl -X POST -H 'Origin: http://10.99.0.1:8002' $P/logout | grep -q 'logged out'; }
check "same-site logout works" same_site_logout
xsite_login() { ccurl -H 'Origin: http://evil.example' -d 'username=regr&password=pw1' $P/login | grep -q 'You are connected'; }
check_not "cross-site login POST refused" xsite_login
check "login without Origin/Referer (captive assistants) works" login regr pw1
trial_over() { ccurl -d 'trial=yes' $P/login | grep -q 'You are connected'; }
check_not "a trial cannot replace a real session" trial_over
logout_client
wrthotspot user add T-account password=pw2 >/dev/null
t_user() { login T-account pw2 && wrthotspot sessions | grep -q 'T-account'; }
check "a user called T-... logs in as itself" t_user
logout_client
wrthotspot user del T-account >/dev/null
# MikroTik's stock trial link: username=T-<the client's MAC>, no password.
# Either a trial starts or the used-up trial is refused; never a PAP login.
mt_trial() { ccurl "$P/login?username=T-02%3A00%3A00%3A00%3A99%3A10" | grep -qE 'You are connected|free trial used up'; }
check "MikroTik trial link (username=T-<mac>) is a trial request" mt_trial
logout_client
other_mac() { ccurl "$P/login?username=T-02%3A00%3A00%3A00%3A99%3A11" | grep -qE 'You are connected|free trial'; }
check_not "T-<another MAC> is not a trial request" other_mac

echo "== limits"
wrthotspot user set regr limit_bytes_total=1 >/dev/null
hs user_reset_counters '{"name":"regr"}' >/dev/null
login regr pw1
ccurl -o /dev/null http://10.98.0.2/index.html
sleep 12
check_not "used-up quota: logged out" online4
quota_refused() { ccurl -d 'username=regr&password=pw1' $P/login | grep -qE 'traffic limit reached|limit of this account has been reached'; }
check "re-login with a used-up quota refused" quota_refused
wrthotspot user set regr limit_bytes_total=0 >/dev/null

echo "== API and config"
revoke_refused() { hs voucher_revoke '{}' | grep -q 'batch is required'; }
regular_kept() { wrthotspot users | grep -q regr; }
check "voucher_revoke without a batch refused" revoke_refused
check "regular users survive it" regular_kept
uci add wrthotspot walled_garden >/dev/null
uci set wrthotspot.@walled_garden[-1].dst_port='443-80'
uci add wrthotspot ip_binding >/dev/null
uci set wrthotspot.@ip_binding[-1].type=bypassed; uci set wrthotspot.@ip_binding[-1].address=10.200.0.0/16
uci add wrthotspot ip_binding >/dev/null
uci set wrthotspot.@ip_binding[-1].type=bypassed; uci set wrthotspot.@ip_binding[-1].address=10.200.1.2
uci commit wrthotspot
reload_hs
port_rejected() { nft list chain inet wrthotspot forward >/dev/null && logread | tail -60 | grep -q 'invalid dst_port'; }
merged() { nft list set inet wrthotspot bypass4 | grep -q '10.200.0.0/16'; }
check "reversed port range rejected, ruleset still loads" port_rejected
check "overlapping bypass networks load (auto-merge)" merged
uci -q delete wrthotspot.@walled_garden[-1]; uci -q delete wrthotspot.@ip_binding[-1]; uci -q delete wrthotspot.@ip_binding[-1]
uci commit wrthotspot
reload_hs

if command -v radclient >/dev/null && [ -f /usr/share/ucode/wrthotspot/radius.uc ]; then
	echo "== CoA replay"
	uci set wrthotspot.regrrad=radius; uci set wrthotspot.regrrad.address=127.0.0.1; uci set wrthotspot.regrrad.secret=testing123
	uci commit wrthotspot; reload_hs
	login regr pw1
	sid=$(hs sessions | jsonfilter -e '@.sessions[0].id')
	old=$(( $(date +%s) - 3600 ))
	printf 'Acct-Session-Id = "%s"\nEvent-Timestamp = %s\nMessage-Authenticator = 0x00\n' "$sid" "$old" |
		radclient -r1 -t2 127.0.0.1:3799 disconnect testing123 >/dev/null 2>&1
	sleep 1
	check "Disconnect with an hour-old Event-Timestamp ignored" online4
	fresh_ok() {
		printf 'Acct-Session-Id = "%s"\nEvent-Timestamp = %s\nMessage-Authenticator = 0x00\n' "$sid" "$(date +%s)" |
			radclient -r2 -t6 127.0.0.1:3799 disconnect testing123 2>&1 | grep -q 'Disconnect-ACK'
	}
	check "a current Disconnect still works" fresh_ok
	logout_client
	uci -q delete wrthotspot.regrrad; uci commit wrthotspot; reload_hs
fi

logout_client
wrthotspot user del regr >/dev/null

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
