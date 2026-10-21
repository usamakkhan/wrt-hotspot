#!/bin/sh
# Login page sets: the pages_* API (as LuCI uses it) and the portal serving
# an uploaded set. Runs on the test router with the service enabled; restores
# the default profile's html_directory and removes its uploads afterwards.
# (Checks call shell functions directly: functions do not exist in `sh -c`.)

PORT=$(uci -q get wrthotspot.@global[0].portal_port || echo 8002)
P="http://127.0.0.1:$PORT"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok    $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
check()     { d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
check_not() { d=$1; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }

hs() { ubus call wrthotspot "$@"; }
b64() { ucode -e 'print(b64enc(ARGV[0]))' "$1"; }
okcall() { hs "$@" | jsonfilter -e '@.ok' | grep -qx true; }
# begin NAME [VAR]: start an upload, its token goes to $TOK (or VAR)
begin() { t=$(hs pages_begin "{\"name\":\"$1\"}" | jsonfilter -e '@.token'); eval "${2:-TOK}=\$t"; [ -n "$t" ]; }
# put NAME PATH DATA [OFFSET [TOKEN]]
put() { okcall pages_put "{\"name\":\"$1\",\"token\":\"${5:-$TOK}\",\"path\":\"$2\",\"data\":\"$(b64 "$3")\",\"offset\":${4:-0}}"; }
commit() { okcall pages_commit "{\"name\":\"$1\",\"token\":\"${2:-$TOK}\"}"; }
get() { curl -s -m 5 "$@"; }
page_has() { get "$P$1" | grep -q "$2"; }
type_is() { get -o /dev/null -w '%{http_code} %{content_type}' "$P$1" | grep -q "^200 $2"; }

# Unknown clients (this router itself) get the profile called "default".
SP=$(uci show wrthotspot | sed -n "s/^wrthotspot\.\([^.=]*\)\.name='default'$/\1/p" | head -1)
OLD=$(uci -q get wrthotspot.$SP.html_directory)
use_dir() { uci set wrthotspot.$SP.html_directory="$1"; uci commit wrthotspot; /etc/init.d/wrthotspot reload; sleep 3; }
cleanup() {
	if [ -n "$OLD" ]; then uci set wrthotspot.$SP.html_directory="$OLD"; else uci -q delete wrthotspot.$SP.html_directory; fi
	uci commit wrthotspot
	rm -rf /etc/wrthotspot/pages/hstest1 /tmp/wrthotspot-pages/hstest1.* /tmp/wrthotspot-pages/hsstale.*
	/etc/init.d/wrthotspot reload; sleep 2
}
trap cleanup EXIT

builtins_listed() { [ "$(hs pages_list | jsonfilter -e '@.pages[@.builtin=true].name' | sort | tr '\n' ' ')" = "classic default " ]; }
limits_listed() { [ "$(hs pages_list | jsonfilter -e '@.limits.chunk')" -gt 0 ]; }
stage_gone() { ! ls -d /tmp/wrthotspot-pages/hstest1.* >/dev/null 2>&1; }
three_files() { [ "$(hs pages_list | jsonfilter -e '@.pages[@.name="hstest1"].files')" = 3 ]; }
file_list() { [ "$(hs pages_files '{"name":"hstest1"}' | jsonfilter -e '@.files[*].path' | tr '\n' ' ')" = "css/site.css img/a/b/x.svg login.html " ]; }
read_back() { [ "$(hs pages_read '{"name":"hstest1","path":"css/site.css","offset":0}' | jsonfilter -e '@.data')" = "$(b64 'body{color:red}')" ]; }
used_by_default() { hs pages_list | jsonfilter -e '@.pages[@.name="hstest1"].used_by[*]' | grep -qx default; }
no_raw_tags() { ! get "$P/login" | grep -q '\$(if\|\$(endif\|\$(identity\|\$(link'; }

[ -n "$SP" ] || { echo "no server profile called default"; exit 1; }
rm -rf /etc/wrthotspot/pages/hstest1

echo "== listing"
check "built-in sets: classic and default" builtins_listed
if [ -e /www/cgi-bin/luci ]; then
	check "default page links router settings" page_has /login 'Router settings'
fi
check "limits reported" limits_listed

echo "== upload rules"
check_not "invalid set name" okcall pages_begin '{"name":"../x"}'
check_not "built-in name refused" okcall pages_begin '{"name":"classic"}'
TOK=0000000000000000
check_not "put without begin" put hstest1 login.html x
check "begin returns a token" begin hstest1
check_not "wrong token refused" put hstest1 login.html x 0 0123456789abcdef
check_not "parent path refused" put hstest1 ../evil.html x
check_not "absolute path refused" put hstest1 /etc/evil.html x
check_not "shell script refused" put hstest1 run.sh x
check_not "hidden file refused" put hstest1 .htaccess.txt x
check_not "'..' inside a name refused (the portal never serves it)" put hstest1 js/a..b.js x
check_not "invalid base64 refused" okcall pages_put "{\"name\":\"hstest1\",\"token\":\"$TOK\",\"path\":\"a.txt\",\"data\":\"!!!\",\"offset\":0}"
check "css file, first chunk" put hstest1 css/site.css "body{color:red}"
check "css file, second chunk" put hstest1 css/site.css "/*end*/" 15
check_not "chunk out of order refused" put hstest1 css/site.css "x" 99
check_not "commit without login.html refused" commit hstest1
check "upload area removed after a failed commit" stage_gone
check_not "nothing installed by the failed commit" test -e /etc/wrthotspot/pages/hstest1

mkdir -p /tmp/wrthotspot-pages/hsstale.0123456789abcdef && touch -d '2020-01-01 00:00:00' /tmp/wrthotspot-pages/hsstale.0123456789abcdef
begin hstest1
check "an abandoned upload is cleared by the next one" test ! -d /tmp/wrthotspot-pages/hsstale.0123456789abcdef

echo "== two uploads of the same name"
begin hstest1 A; begin hstest1 B
put hstest1 login.html 'UPLOAD-A' 0 "$A"
put hstest1 login.html 'UPLOAD-B' 0 "$B"
check "the second upload leaves the first one alone" commit hstest1 "$A"
check "the second upload still commits" commit hstest1 "$B"
check "the later commit wins" grep -q UPLOAD-B /etc/wrthotspot/pages/hstest1/login.html

echo "== upload and use"
begin hstest1
put hstest1 login.html "<html><link href=\"css/site.css\">HSTEST-LOGIN \$(if trial == 'no')quoted-ok\$(endif)</html>"
put hstest1 css/site.css "body{color:red}"
put hstest1 img/a/b/x.svg "<svg/>"
check "commit" commit hstest1
check "installed under /etc/wrthotspot/pages" test -f /etc/wrthotspot/pages/hstest1/css/site.css
check "listed with 3 files" three_files
check "file list" file_list
check "read back (base64) matches" read_back
check_not "read outside the set refused" okcall pages_read '{"name":"hstest1","path":"../../config/wrthotspot.txt","offset":0}'

use_dir /etc/wrthotspot/pages/hstest1
check "listed as used by the default profile" used_by_default
check "portal shows the uploaded login page" page_has /login HSTEST-LOGIN
check "MikroTik-style quoted comparison works" page_has /login quoted-ok
check "static file from the set" page_has /css/site.css 'color:red'
check "css content type" type_is /css/site.css text/css
check "missing page falls back to the built-in one" page_has /status 'not logged in'
check_not "set in use cannot be removed" okcall pages_remove '{"name":"hstest1"}'

echo "== replace"
ET=$(get -D - -o /dev/null "$P/css/site.css" | sed -n 's/^ETag: *//Ip' | tr -d '\r')
revalidate() { get -o /dev/null -w '%{http_code}' -H "If-None-Match: $ET" "$P/css/site.css"; }
not_modified() { [ "$(revalidate)" = 304 ]; }
modified() { [ "$(revalidate)" = 200 ]; }
check "static files carry an ETag" test -n "$ET"
check "unchanged static file: 304 Not Modified" not_modified
begin hstest1
put hstest1 login.html 'HSTEST-V2'
put hstest1 css/site.css 'body{color:blue}'
check "replace" commit hstest1
check "old files gone after replace" test ! -e /etc/wrthotspot/pages/hstest1/img/a/b/x.svg
check "portal shows the new version" page_has /login HSTEST-V2
check "a replaced static file no longer matches the old ETag" modified
check "a replaced static file is served new" page_has /css/site.css 'color:blue'

echo "== classic set"
use_dir /usr/share/wrthotspot/pages/classic
check "classic login page links the project" page_has /login 'github.com/usamakkhan/wrt-hotspot'
if [ -e /www/cgi-bin/luci ]; then
	check "classic page links router settings" page_has /login 'Router settings'
fi
check "classic stylesheet" type_is /css/style.css text/css
check "classic logo" type_is /img/logo.svg image/svg
check "classic md5.js" type_is /md5.js application/javascript
check "no unrendered template tags" no_raw_tags
# Saved for the profile but not reloaded yet: still in use.
uci set wrthotspot.$SP.html_directory=/etc/wrthotspot/pages/hstest1; uci commit wrthotspot
check_not "a set chosen in the saved config cannot be removed" okcall pages_remove '{"name":"hstest1"}'
uci set wrthotspot.$SP.html_directory=/usr/share/wrthotspot/pages/classic; uci commit wrthotspot
check "an unused upload can be removed" okcall pages_remove '{"name":"hstest1"}'
check_not "built-in set cannot be removed" okcall pages_remove '{"name":"classic"}'

echo "RESULT: $PASS passed, $FAIL failed"
[ $FAIL = 0 ]
