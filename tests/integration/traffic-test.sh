#!/bin/sh
# Real-traffic concurrency test: N clients (own netns + veth, own MAC,
# IPv4 + IPv6) are redirected, log in through the portal at the same time
# and download through the shaper. Checks sessions, accounting and rates.
#
# Run on the test router after `netns-test.sh keep`:
#   sh traffic-test.sh [N (max 200)] [rate-limit] [download KiB]

N=${1:-200}
RATE=${2:-1M/4M}
KIB=${3:-1024}
P="http://10.99.0.1:8002"
TX=$(echo "$RATE" | sed 's|.*/||')
pass=0; fail=0

check() {	# check <name> <condition result 0/1> [detail]
	if [ "$2" = 0 ]; then pass=$((pass + 1)); echo "  ok    $1 $3"; else fail=$((fail + 1)); echo "  FAIL  $1 $3"; fi
}

ns() { echo "hsm$1"; }
cleanup() {
	for i in $(seq 1 "$N"); do ip netns del "$(ns "$i")" 2>/dev/null; ip link del "hsm${i}p" 2>/dev/null; done
	rm -rf /tmp/hsm /tmp/hsinet-www/traffic.bin
	uci -q delete wrthotspot.trafprof; uci commit wrthotspot
}

if [ "$N" = cleanup ]; then N=200; cleanup; exit 0; fi
[ "$N" -le 200 ] || { echo "N must be <= 200 (one /24)"; exit 1; }
ip link show br-hstest >/dev/null 2>&1 || { echo "run netns-test.sh keep first"; exit 1; }
cleanup 2>/dev/null
mkdir -p /tmp/hsm

echo "== traffic test: $N clients, rate limit $RATE, ${KIB} KiB per download"

uci set wrthotspot.trafprof=user_profile
uci set wrthotspot.trafprof.rate_limit="$RATE"
uci set wrthotspot.trafprof.shared_users=1
uci commit wrthotspot
ubus call wrthotspot reload >/dev/null
sleep 2
dd if=/dev/urandom of=/tmp/hsinet-www/traffic.bin bs=1k count="$KIB" 2>/dev/null

# Clients: one netns each, attached to the hotspot bridge by a veth pair.
t0=$(date +%s)
for i in $(seq 1 "$N"); do
	n=$(ns "$i")
	ip netns add "$n"
	ip link add "hsm${i}p" type veth peer name "hsm${i}c"
	ip link set "hsm${i}c" address "$(printf '02:bb:00:00:00:%02x' "$i")" netns "$n"
	ip link set "hsm${i}p" master br-hstest up
	ip netns exec "$n" sh -c "
		ip link set lo up; ip link set hsm${i}c name eth0 up
		ip addr add 10.99.0.$((i + 50))/24 dev eth0
		ip -6 addr add fd99::2:$i/64 dev eth0 nodad
		ip route add default via 10.99.0.1
		ip -6 route add default via fd99::1"
done
echo "   $N clients created in $(( $(date +%s) - t0 )) s"

# Vouchers.
ubus call wrthotspot voucher_create "{\"profile\":\"trafprof\",\"count\":$N,\"length\":8,\"charset\":\"alnum\",\"comment\":\"traffic test\"}" |
	jsonfilter -e '@.vouchers[*].name' > /tmp/hsm/codes
check "vouchers created" "$([ "$(wc -l < /tmp/hsm/codes)" = "$N" ]; echo $?)"
# SETUP_ONLY=1: leave the clients in place (remove with `traffic-test.sh cleanup`).
[ "${SETUP_ONLY:-0}" = 1 ] && exit 0

# Every client at once, stage by stage: redirect, login, IPv4 download, IPv6
# download. One bare curl per client and stage: the clients share the
# router's RAM, so no helper shell per client.
stage() {	# stage <name> <curl args>; the login stage posts the client's voucher
	name=$1; shift
	t1=$(date +%s)
	i=0
	while read -r code; do
		i=$((i + 1))
		if [ "$name" = login ]; then
			ip netns exec "$(ns "$i")" curl -s -d "username=$code&password=$code&dst=http://10.98.0.2/" "$@" > "/tmp/hsm/$i.$name" &
		else
			ip netns exec "$(ns "$i")" curl -s "$@" > "/tmp/hsm/$i.$name" &
		fi
	done < /tmp/hsm/codes
	wait
	echo "   stage $name: $(( $(date +%s) - t1 )) s"
}

W='%{http_code} %{size_download} %{speed_download}\n'
t0=$(date +%s)
stage redir -m 20 -o /dev/null -w '%{http_code}' http://10.98.0.2/x
stage login -m 30 "$P/login"
stage v4 -m 90 -o /dev/null -w "$W" http://10.98.0.2/traffic.bin
stage v6 -m 90 -o /dev/null -w "$W" 'http://[fd98::2]/traffic.bin'
dt=$(( $(date +%s) - t0 ))

redir=$(grep -l '^302$' /tmp/hsm/*.redir | wc -l)
logged=$(grep -l 'You are connected' /tmp/hsm/*.login | wc -l)
v4=$(grep -l "^200 $((KIB * 1024)) " /tmp/hsm/*.v4 | wc -l)
v6=$(grep -l "^200 $((KIB * 1024)) " /tmp/hsm/*.v6 | wc -l)
check "all clients redirected before login" "$([ "$redir" = "$N" ]; echo $?)" "($redir/$N)"
check "all concurrent portal logins succeeded" "$([ "$logged" = "$N" ]; echo $?)" "($logged/$N)"
check "all IPv4 downloads complete" "$([ "$v4" = "$N" ]; echo $?)" "($v4/$N)"
check "all IPv6 downloads complete" "$([ "$v6" = "$N" ]; echo $?)" "($v6/$N)"
echo "   wall time for redirect + login + 2 downloads, all clients: $dt s"

# Rates: the shaper must hold every client at its download limit.
lim=$(echo "$TX" | awk '{ v = $1 + 0; u = tolower(substr($1, length($1))); if (u == "k") v *= 1e3; if (u == "m") v *= 1e6; if (u == "g") v *= 1e9; print v }')
cat /tmp/hsm/*.v4 /tmp/hsm/*.v6 | awk -v lim="$lim" '
	{ r = $3 * 8; s += r; n++; if (r > max) max = r; if (min == "" || r < min) min = r; if (r > lim * 1.10) over++ }
	END { printf "%d %.0f %.0f %.0f %d\n", n, min, s / n, max, over }' > /tmp/hsm/rates
read -r cnt rmin ravg rmax over < /tmp/hsm/rates
echo "   per-download rate kbit/s: min $((rmin / 1000)) avg $((ravg / 1000)) max $((rmax / 1000)) (limit $((lim / 1000)))"
check "no download above the rate limit (+10%)" "$([ "$over" = 0 ]; echo $?)" "($over over)"

# Accounting: every session counted at least what it downloaded.
sleep 12	# one poll interval
ubus call wrthotspot sessions '{"limit":1000}' > /tmp/hsm/sessions.json
sess=$(jsonfilter -i /tmp/hsm/sessions.json -e '@.total')
check "one session per client" "$([ "$sess" -ge "$N" ]; echo $?)" "($sess)"
# "<mac> <bytes_out>" for the test clients.
jsonfilter -i /tmp/hsm/sessions.json -e '@.sessions[*].mac' > /tmp/hsm/macs
jsonfilter -i /tmp/hsm/sessions.json -e '@.sessions[*].bytes_out' > /tmp/hsm/down
awk 'NR == FNR { m[FNR] = $1; next } m[FNR] ~ /^02:bb:/ { print m[FNR], $1 }' /tmp/hsm/macs /tmp/hsm/down > /tmp/hsm/acct
short=$(wc -l < /tmp/hsm/acct)
under=$(awk -v min=$((KIB * 2048)) '$2 < min' /tmp/hsm/acct | wc -l)
check "download accounting >= bytes delivered (v4 + v6)" "$([ "$short" = "$N" ] && [ "$under" = 0 ]; echo $?)" "($short sessions, $under under)"
total=$(awk '{ s += $2 } END { printf "%.1f", s / 1048576 }' /tmp/hsm/acct)
echo "   accounted downloads: $total MiB (delivered $((N * KIB * 2 / 1024)) MiB)"
echo "   daemon: $(ubus call wrthotspot status | jsonfilter -e '@.rss_kb') KiB RSS, poll $(ubus call wrthotspot status | jsonfilter -e '@.poll_ms') ms; free $(awk '/MemAvailable/{print $2}' /proc/meminfo) KiB"

# Logout everybody concurrently through the portal, then they must be blocked.
for i in $(seq 1 "$N"); do
	ip netns exec "$(ns "$i")" curl -s -m 20 -o /dev/null "$P/logout" &
done
wait
sleep 2
blocked=0
for i in $(seq 1 "$N"); do
	[ "$(ip netns exec "$(ns "$i")" curl -s -m 5 -o /dev/null -w '%{http_code}' http://10.98.0.2/x)" = 302 ] && blocked=$((blocked + 1))
done
check "all clients redirected again after portal logout" "$([ "$blocked" = "$N" ]; echo $?)" "($blocked/$N)"

for b in $(ubus call wrthotspot voucher_batches | jsonfilter -e '@.batches[@.comment="traffic test"].batch'); do
	ubus call wrthotspot voucher_revoke "{\"batch\":\"$b\",\"all\":true}" >/dev/null
done
cleanup
ubus call wrthotspot reload >/dev/null

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
