#!/bin/sh
# Operator panel API: vouchers, history, reports, operator accounts and the
# rpcd ACLs that confine staff. Runs on the router; needs the netns topology
# from netns-test.sh (run that with "keep" first) and the panel ACL installed.

P="http://10.99.0.1:8002"
PASS=0
FAIL=0
Z=00000000000000000000000000000000

C() { ip netns exec hsclient "$@"; }
ok()  { PASS=$((PASS+1)); echo "  ok    $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
check()     { d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
check_not() { d=$1; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
online4() { [ "$(C curl -s -m 5 -o /dev/null -w '%{http_code}' http://10.98.0.2/)" = 200 ]; }
portal_login_has() { C curl -s -m 5 -d "username=$1&password=$2" "$P/login" | grep -q "$3"; }

# JSON-RPC over HTTP exactly like the panel (127.0.0.1 = the router's web server).
rpc() {	# sid object method json
	curl -s -m 10 http://127.0.0.1/ubus -H 'Content-Type: application/json' \
		-d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"$1\",\"$2\",\"$3\",$4]}"
}
rpc_has() { rpc "$1" "$2" "$3" "$4" | grep -q "$5"; }	# reply matches
rpc_ok() { rpc "$1" "$2" "$3" "$4" | grep -q '"result":\[0'; }	# call permitted
login_sid() { rpc $Z session login "{\"username\":\"$1\",\"password\":\"$2\"}" | jsonfilter -e '@.result[1].ubus_rpc_session'; }
hash_salted() { uci show rpcd | grep -q "password='[$]1[$][./0-9A-Za-z]\{8\}[$]"; }
ub_has() { ubus call wrthotspot "$1" "$2" | grep -q "$3"; }	# local ubus reply matches
ub_val() { ubus call wrthotspot "$1" "$2" | jsonfilter -e "$3"; }

ACL="$(dirname "$0")/../../feed/net/wrt-hotspot-panel/files/usr/share/rpcd/acl.d/wrthotspot-panel.json"
if ! cmp -s "$ACL" /usr/share/rpcd/acl.d/wrthotspot-panel.json; then
	cp "$ACL" /usr/share/rpcd/acl.d/ && /etc/init.d/rpcd reload && sleep 1
fi

# The kept topology may require HTTPS login; use plain HTTP PAP here.
uci -q del_list wrthotspot.@server_profile[0].login_by=https
uci -q del_list wrthotspot.@server_profile[0].login_by=mac
uci -q set wrthotspot.@server_profile[0].use_radius=0
uci commit wrthotspot
/etc/init.d/wrthotspot reload
sleep 3
wrthotspot logout 02:00:00:00:99:10 >/dev/null 2>&1
wrthotspot cookie del 02:00:00:00:99:10 >/dev/null 2>&1

echo "== vouchers"
out=$(ubus call wrthotspot voucher_create '{"profile":"testprof","count":5,"length":6,"charset":"digits","prefix":"T","validity":"20s","price":"2.50","comment":"api test"}')
batch=$(echo "$out" | jsonfilter -e '@.batch')
code=$(echo "$out" | jsonfilter -e '@.vouchers[0].name')
check "batch created" [ -n "$batch" ]
check "5 vouchers in batch" [ "$(echo "$out" | jsonfilter -e '@.vouchers[*].name' | wc -l)" = 5 ]
check "PIN mode: password equals code" [ "$(echo "$out" | jsonfilter -e '@.vouchers[0].password')" = "$code" ]
check "code uses prefix and digits" sh -c "echo '$code' | grep -qE '^T[0-9]{6}$'"
check "batch listed, none used" [ "$(ub_val voucher_batches '{}' "@.batches[@.batch='$batch'].used")" = 0 ]
check "voucher_list gives printable codes" ub_has voucher_list "{\"batch\":\"$batch\"}" "$code"
check_not "bad charset rejected" ub_has voucher_create '{"count":1,"charset":"klingon"}' '"ok": true'
# 1000 accounts exceed a small router's capacity, which is checked first:
# lift the account limit so that the code-space check is reached.
old_max_users=$(uci -q get wrthotspot.global.max_users)
uci set wrthotspot.global.max_users=100000; uci commit wrthotspot; ubus call wrthotspot reload >/dev/null; sleep 1
check "too small code space rejected" ub_has voucher_create '{"count":1000,"length":4,"charset":"digits"}' 'code space'
if [ -n "$old_max_users" ]; then uci set wrthotspot.global.max_users="$old_max_users"; else uci -q delete wrthotspot.global.max_users; fi
uci commit wrthotspot; ubus call wrthotspot reload >/dev/null; sleep 1

check "voucher logs in with the code alone (empty password)" portal_login_has "$code" "" 'You are connected'
check "online with voucher" online4
check "validity starts at first login" sh -c "ubus call wrthotspot user_get '{\"name\":\"$code\"}' | jsonfilter -e '@.user.expires' | grep -qE '^[0-9]+$'"
t=$(ub_val sessions '{}' "@.sessions[@.user='$code'].limits.max_uptime")
check "session limited to the voucher validity ($t s)" [ "${t:-0}" -gt 0 -a "${t:-99}" -le 20 ]
check "batch shows one used" [ "$(ub_val voucher_batches '{}' "@.batches[@.batch='$batch'].used")" = 1 ]
sleep 22
check_not "voucher session ended at validity" online4
check "expired voucher refused" portal_login_has "$code" "" 'voucher has expired'

echo "== history and reports"
check "history has the voucher session" [ "$(ub_val history "{\"search\":\"$code\"}" '@.history[0].user')" = "$code" ]
check "history records the batch" [ "$(ub_val history "{\"search\":\"$code\"}" '@.history[0].batch')" = "$batch" ]
check "history records the cause" [ "$(ub_val history "{\"search\":\"$code\"}" '@.history[0].cause')" = uptime-limit ]
r=$(ubus call wrthotspot report '{"group":"batch"}')
check "report counts the activation" [ "$(echo "$r" | jsonfilter -e "@.rows[@.key='$batch'].activations")" = 1 ]
check "report sums the revenue" sh -c "echo '$r' | jsonfilter -e \"@.rows[@.key='$batch'].revenue\" | grep -q '^2.5'"
check "report by day has a row for today" sh -c "ubus call wrthotspot report '{\"group\":\"day\"}' | jsonfilter -e '@.rows[*].key' | grep -q $(date +%Y-%m-%d)"
check "revoke deletes the unused vouchers only" [ "$(ub_val voucher_revoke "{\"batch\":\"$batch\"}" '@.count')" = 4 ]
check "used voucher kept after revoke" ub_has user_get "{\"name\":\"$code\"}" '"ok": true'

echo "== operators and ACLs"
ubus call wrthotspot operator_remove '{"username":"staff1"}' >/dev/null 2>&1
ubus call wrthotspot operator_remove '{"username":"boss1"}' >/dev/null 2>&1
check "create operator" ub_has operator_set '{"username":"staff1","password":"Staff-pass-1","role":"operator"}' '"ok": true'
check "create admin" ub_has operator_set '{"username":"boss1","password":"Boss-pass-1","role":"admin"}' '"ok": true'
check_not "root cannot be managed" ub_has operator_set '{"username":"root","password":"xxxxxxx","role":"admin"}' '"ok": true'
check_not "short password refused" ub_has operator_set '{"username":"staff2","password":"abc","role":"operator"}' '"ok": true'
check "salted MD5-crypt hash stored" hash_salted

sid=$(login_sid staff1 Staff-pass-1)
check "operator logs in through rpcd (salted hash accepted by crypt)" [ -n "$sid" ]
check_not "wrong password refused" [ -n "$(login_sid staff1 nope-nope)" ]
check "operator: whoami" rpc_has "$sid" wrthotspot whoami '{}' '"username":"staff1"'
check "operator: not admin" rpc_has "$sid" wrthotspot whoami '{}' '"admin":false'
check "operator: may create vouchers" rpc_has "$sid" wrthotspot voucher_create '{"count":2,"profile":"default"}' '"ok":true'
check "batch records the operator" ub_has voucher_batches '{}' '"created_by": "staff1"'
check "operator: may list sessions" rpc_ok "$sid" wrthotspot sessions '{}'
check "operator: may read reports" rpc_ok "$sid" wrthotspot report '{}'
check "operator: may manage users" rpc_has "$sid" wrthotspot user_set '{"name":"panel-made","password":"pw123456","profile":"default"}' '"ok":true'
check_not "operator: no operator management" rpc_ok "$sid" wrthotspot operator_list '{}'
check_not "operator: no UCI access" rpc_ok "$sid" uci get '{"config":"wrthotspot"}'
check_not "operator: no flush" rpc_ok "$sid" wrthotspot flush '{}'
check_not "operator: no file access" rpc_ok "$sid" file read '{"path":"/etc/shadow"}'
check_not "operator: no other ubus objects" rpc_ok "$sid" system board '{}'

asid=$(login_sid boss1 Boss-pass-1)
check "admin: whoami says admin" rpc_has "$asid" wrthotspot whoami '{}' '"admin":true'
check "admin: lists operators" rpc_has "$asid" wrthotspot operator_list '{}' staff1

# Capacity: the router is "full"; operators are refused, admins may force.
n=$(ub_val status '{}' '@.users')
uci set wrthotspot.global.max_users="$n"; uci commit wrthotspot; ubus call wrthotspot reload >/dev/null; sleep 1
check "capacity: refusal carries the capacity details" rpc_has "$sid" wrthotspot user_set '{"name":"capx1","password":"pw123456"}' '"capacity"'
check_not "capacity: operator force is ignored" rpc_has "$sid" wrthotspot user_set '{"name":"capx1","password":"pw123456","force":true}' '"ok":true'
check_not "capacity: operator batch refused" rpc_has "$sid" wrthotspot voucher_create '{"count":2,"profile":"default","force":true}' '"ok":true'
check "capacity: admin force adds with a warning" rpc_has "$asid" wrthotspot user_set '{"name":"capx2","password":"pw123456","force":true}' '"warning"'
check "capacity: admin forced batch" rpc_has "$asid" wrthotspot voucher_create '{"count":2,"profile":"default","comment":"cap test","force":true}' '"ok":true'
uci -q delete wrthotspot.global.max_users; uci commit wrthotspot; ubus call wrthotspot reload >/dev/null
wrthotspot user del capx2 >/dev/null 2>&1
for b in $(ubus call wrthotspot voucher_batches | jsonfilter -e '@.batches[@.comment="cap test"].batch'); do
	ubus call wrthotspot voucher_revoke "{\"batch\":\"$b\",\"all\":true}" >/dev/null
done
check_not "admin: still no UCI" rpc_ok "$asid" uci get '{"config":"network"}'
check_not "admin cannot delete itself" rpc_has "$asid" wrthotspot operator_remove '{"username":"boss1"}' '"ok":true'
check "admin removes operator" rpc_has "$asid" wrthotspot operator_remove '{"username":"staff1"}' '"ok":true'
check_not "removed operator cannot log in" [ -n "$(login_sid staff1 Staff-pass-1)" ]

ubus call wrthotspot operator_remove '{"username":"boss1"}' >/dev/null
wrthotspot user del panel-made >/dev/null 2>&1

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
