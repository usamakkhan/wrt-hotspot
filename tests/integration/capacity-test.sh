#!/bin/sh
# Capacity limits: refused beyond max_users / max_sessions, admin force and
# capacity_override let it through with warnings. Run on the test router
# after `netns-test.sh keep`.

pass=0; fail=0
check() {	# check <name> <0/1> [detail]
	if [ "$2" = 0 ]; then pass=$((pass + 1)); echo "  ok    $1 $3"; else fail=$((fail + 1)); echo "  FAIL  $1 $3"; fi
}
hs() { ubus call wrthotspot "$@"; }
yes_if() { [ "$1" ]; echo $?; }
mac() { printf '02:dd:00:00:00:%02x' "$1"; }

users0=$(hs status | jsonfilter -e '@.users')
sess0=$(hs status | jsonfilter -e '@.sessions')

uci set wrthotspot.global.max_users=$((users0 + 2))
uci set wrthotspot.global.max_sessions=$((sess0 + 2))
uci commit wrthotspot
hs reload >/dev/null
sleep 1

echo "== user accounts (limit $((users0 + 2)))"
r=$(hs user_set '{"name":"cap1","password":"x"}')
check "first user within the limit" "$(yes_if "$(echo "$r" | jsonfilter -e '@.ok' | grep true)")"
r=$(hs voucher_create '{"profile":"default","count":5,"comment":"capacity test"}')
check "batch beyond the limit refused" "$(yes_if "$(echo "$r" | jsonfilter -e '@.error' | grep 'exceed')")" "($(echo "$r" | jsonfilter -e '@.error'))"
check "refusal reports the capacity" "$(yes_if "$(echo "$r" | jsonfilter -e '@.capacity.max_users')")"
r=$(hs voucher_create '{"profile":"default","count":5,"comment":"capacity test","force":true}')
check "admin force creates the batch" "$(yes_if "$(echo "$r" | jsonfilter -e '@.ok' | grep true)")"
check "forced batch carries a warning" "$(yes_if "$(echo "$r" | jsonfilter -e '@.warning' | grep 'override')")"
r=$(hs user_set '{"name":"cap2","password":"x"}')
check "new user over the limit refused" "$(yes_if "$(echo "$r" | jsonfilter -e '@.ok' | grep false)")"
r=$(hs user_set '{"name":"cap1","password":"y"}')
check "editing an existing user still works" "$(yes_if "$(echo "$r" | jsonfilter -e '@.ok' | grep true)")"
check "status flags users over the limit" "$(yes_if "$(hs status | jsonfilter -e '@.capacity.over_users' | grep true)")"
out=$(wrthotspot user add cap3 password=x force=1 2>&1)
check "CLI force=1 adds with a warning" "$(yes_if "$(echo "$out" | grep -i 'warning')")"

echo "== sessions (limit $((sess0 + 2)))"
for i in 1 2 3; do
	ip -6 neigh replace "fd99::3:$i" lladdr "$(mac "$i")" dev br-hstest nud permanent
done
sleep 2
hs user_set '{"name":"capsess","password":"pw","force":true}' >/dev/null
uci set wrthotspot.capshared=user_profile; uci set wrthotspot.capshared.name=capshared; uci set wrthotspot.capshared.shared_users=10; uci commit wrthotspot
hs user_set '{"name":"capsess","profile":"capshared"}' >/dev/null
hs reload >/dev/null; sleep 1
login() { hs login "{\"mac\":\"$(mac "$1")\",\"method\":\"http-pap\",\"username\":\"capsess\",\"password\":\"pw\"}"; }
r1=$(login 1); r2=$(login 2); r3=$(login 3)
check "logins within the limit" "$(yes_if "$(echo "$r1$r2" | grep -c '"ok": true' | grep 2)")"
check "login beyond the limit refused" "$(yes_if "$(echo "$r3" | grep 'full')")" "($(echo "$r3" | jsonfilter -e '@.error'))"
check "refusal logged" "$(yes_if "$(logread | tail -20 | grep 'Capacity:.*logins refused')")"

uci set wrthotspot.global.capacity_override=1; uci commit wrthotspot; hs reload >/dev/null; sleep 1
r3=$(login 3)
check "capacity_override lets the login through" "$(yes_if "$(echo "$r3" | grep '"ok": true')")"
check "status flags sessions over the limit" "$(yes_if "$(hs status | jsonfilter -e '@.capacity.over_sessions' | grep true)")"

echo "== auto limits"
uci -q delete wrthotspot.global.max_users; uci -q delete wrthotspot.global.max_sessions
uci -q delete wrthotspot.global.capacity_override; uci commit wrthotspot; hs reload >/dev/null; sleep 1
c=$(hs status)
check "auto limits computed" "$(yes_if "$(echo "$c" | jsonfilter -e '@.capacity.max_sessions' | grep -v '^0$')")" \
	"($(echo "$c" | jsonfilter -e '@.capacity.tier.label') tier: $(echo "$c" | jsonfilter -e '@.capacity.max_sessions') sessions, $(echo "$c" | jsonfilter -e '@.capacity.max_users') users)"
uci set wrthotspot.global.capacity=off; uci commit wrthotspot; hs reload >/dev/null; sleep 1
check "capacity off: no limits" "$(yes_if "$(hs status | jsonfilter -e '@.capacity.mode' | grep off)")"

# Cleanup.
for i in 1 2 3; do hs logout "{\"mac\":\"$(mac "$i")\",\"cause\":\"admin-reset\"}" >/dev/null; ip -6 neigh del "fd99::3:$i" dev br-hstest; done
for u in cap1 cap2 cap3 capsess; do hs user_remove "{\"name\":\"$u\"}" >/dev/null; done
for b in $(hs voucher_batches | jsonfilter -e '@.batches[@.comment="capacity test"].batch'); do
	hs voucher_revoke "{\"batch\":\"$b\",\"all\":true}" >/dev/null
done
uci -q delete wrthotspot.global.capacity; uci -q delete wrthotspot.capshared; uci commit wrthotspot; hs reload >/dev/null

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
