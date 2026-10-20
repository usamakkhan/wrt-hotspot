// RouterOS API subset, end to end over TCP. Run on the test router after
// `netns-test.sh keep` (needs wrt-hotspot-radius):  ucode rosapi-test.uc
'use strict';

import * as socket from 'socket';
import * as ubus from 'ubus';
import * as fs from 'fs';
import { md5 } from 'digest';

const rosapi = require('wrthotspot.rosapi');
let conn = ubus.connect();
let pass = 0, fail = 0;

function check(name, cond, detail) {
	if (cond) { pass++; print(`  ok    ${name}${detail ? ' ' + detail : ''}\n`); }
	else { fail++; print(`  FAIL  ${name}${detail ? ' ' + detail : ''}\n`); }
}

function sh(cmd) {
	let p = fs.popen(`${cmd} 2>&1`, 'r');
	let out = p.read('all');
	p.close();
	return trim(out ?? '');
}

function connect() {
	let s = socket.create(socket.AF_INET, socket.SOCK_STREAM);
	if (!s.connect('127.0.0.1:8728'))
		return null;
	s.setopt(socket.SOL_SOCKET, socket.SO_RCVTIMEO, { sec: 5, usec: 0 });
	return { s, buf: '' };
}

// Send a sentence, read replies up to !done / !fatal.
function call(c, words) {
	c.s.send(rosapi.sentence(words));
	let out = [];

	while (true) {
		let n = rosapi.next_sentence(c.buf);

		if (n == null) {
			let d = c.s.recv(65536);
			if (d == null || d == '')
				return out;
			c.buf += d;
			continue;
		}

		c.buf = substr(c.buf, n[1]);
		let r = { type: n[0][0], attrs: {} };
		for (let w in slice(n[0], 1)) {
			let i = index(substr(w, 1), '=');
			if (substr(w, 0, 1) == '=')
				r.attrs[substr(w, 1, i)] = substr(w, i + 2);
			else
				r.attrs[w] = true;
		}
		push(out, r);

		if (r.type == '!done' || r.type == '!fatal')
			return out;
	}
}

function items(res) {
	return map(filter(res, (r) => r.type == '!re'), (r) => r.attrs);
}

print('== RouterOS API\n');

function word_of(n) {
	let w = 'a';
	while (length(w) < n)
		w += w;
	return substr(w, 0, n);
}

// Wire format round trip for the 1-, 2- and 3-byte length forms (an empty
// word ends a sentence, so lengths start at 1); words over 64 KiB are refused.
let enc_ok = true;
for (let n in [ 1, 0x7f, 0x80, 0x3fff, 0x4000, 0xffff ]) {
	let p = rosapi.next_sentence(rosapi.sentence([ word_of(n), 'x' ]));
	if (!p || length(p[0][0]) != n || p[0][1] != 'x')
		enc_ok = false;
}
check('word length encoding round trip (1-3 byte lengths)', enc_ok);
check('oversized word rejected', rosapi.next_sentence(rosapi.sentence([ word_of(0x20000) ]))?.[0] === null);
check('query: equality, exists, negation, OR',
	rosapi.query_match({ a: '1', b: 'x' }, [ 'a=1', 'b' ]) && !rosapi.query_match({ a: '1' }, [ '-a' ])
	&& rosapi.query_match({ a: '2' }, [ 'a=1', 'a=2', '#|' ]) && !rosapi.query_match({ a: '3' }, [ 'a=1', 'a=2', '#|' ])
	&& rosapi.query_match({ a: '1' }, [ '=a=1' ]) && !rosapi.query_match({ a: '1' }, [ '=a=2' ]));

// Set up: API on, a user for the old challenge login.
sh("uci set wrthotspot.global.api_enable=1; uci set wrthotspot.global.api_user=billing; uci set wrthotspot.global.api_password=apisecret1; uci commit wrthotspot");
conn.call('wrthotspot', 'reload', {});
sleep(1000);
check('API reported in status', conn.call('wrthotspot', 'status', {})?.api?.port == 8728);

let c = connect();
check('TCP connect to 8728', c != null);

let r = call(c, [ '/ip/hotspot/active/print' ]);
check('command before login is refused', r[0]?.type == '!fatal');
c.s.close();

c = connect();
r = call(c, [ '/login', '=name=billing', '=password=wrong' ]);
check('wrong password trapped', r[0]?.type == '!trap');
r = call(c, [ '/login', '=name=billing', '=password=apisecret1' ]);
check('plain login (6.43+)', r[0]?.type == '!done');

let c2 = connect();
r = call(c2, [ '/login' ]);
let ch = r[0]?.attrs?.ret;
check('challenge login: challenge issued', length(ch) == 32);
r = call(c2, [ '/login', '=name=billing', `=response=00${md5(chr(0) + 'apisecret1' + hexdec(ch))}` ]);
check('challenge login (pre-6.43)', r[0]?.type == '!done');
c2.s.close();

r = items(call(c, [ '/system/identity/print' ]));
check('/system/identity/print', length(r[0]?.name), `(${r[0]?.name})`);
r = items(call(c, [ '/system/resource/print' ]));
check('/system/resource/print', r[0]?.version == '7.16' && +r[0]?.['total-memory'] > 0, `(${r[0]?.['board-name']}, ${r[0]?.uptime})`);
r = items(call(c, [ '/interface/print', '?name=br-hstest' ]));
check('/interface/print with query', length(r) == 1 && r[0].type == 'bridge');
r = items(call(c, [ '/ip/hotspot/print' ]));
check('/ip/hotspot/print lists the server', length(filter(r, (x) => x.name == 'hstest')) == 1);
r = call(c, [ '/ppp/active/print' ]);
check('/ppp/active/print is empty, not an error', length(r) == 1 && r[0].type == '!done');
r = call(c, [ '/no/such/print' ]);
check('unknown menu trapped', r[0]?.type == '!trap');

// Users: add (with capacity check), print, set, remove.
r = call(c, [ '/ip/hotspot/user/add', '=name=apiuser', '=password=pw1', '=limit-uptime=1h', '=comment=from api' ]);
check('/ip/hotspot/user/add', r[0]?.type == '!done' && substr(r[0].attrs.ret ?? '', 0, 1) == '*');
let u = conn.call('wrthotspot', 'user_list', { search: 'apiuser' })?.users?.[0];
check('user stored with limit-uptime 1h', u?.limit_uptime == 3600, `(${u?.limit_uptime})`);
r = call(c, [ '/ip/hotspot/user/add', '=name=apiuser' ]);
check('duplicate user trapped', r[0]?.type == '!trap');
r = call(c, [ '/ip/hotspot/user/set', '=numbers=apiuser', '=disabled=yes' ]);
check('/ip/hotspot/user/set by name', r[0]?.type == '!done' && conn.call('wrthotspot', 'user_list', { search: 'apiuser' })?.users?.[0]?.disabled);
call(c, [ '/ip/hotspot/user/set', '=numbers=apiuser', '=disabled=no' ]);
r = items(call(c, [ '/ip/hotspot/user/print', '?name=apiuser', '=.proplist=name,limit-uptime' ]));
check('user print with .proplist', length(r) == 1 && length(keys(r[0])) == 2 && r[0]['limit-uptime'] == '1h');

// Online users: log a simulated client in, list it, disconnect it.
sh('ip -6 neigh replace fd99::4:1 lladdr 02:ee:00:00:00:01 dev br-hstest nud permanent');
sleep(1500);
let li = conn.call('wrthotspot', 'login', { mac: '02:ee:00:00:00:01', method: 'http-pap', username: 'apiuser', password: 'pw1' });
check('client logged in for the API checks', li?.ok);
r = items(call(c, [ '/ip/hotspot/active/print', '?user=apiuser' ]));
check('/ip/hotspot/active/print shows the session', length(r) == 1 && r[0]['mac-address'] == '02:EE:00:00:00:01' && r[0]['login-by'] == 'http-pap',
	`(${r[0]?.['.id']}, uptime ${r[0]?.uptime})`);
let id = r[0]?.['.id'];
r = call(c, [ '/ip/hotspot/active/print', '=count-only=' ]);
check('count-only', +r[0]?.attrs?.ret >= 1);
r = items(call(c, [ '/queue/simple/print', '?name=<hotspot-apiuser>' ]));
check('/queue/simple/print has a dynamic queue', length(r) == 1 && r[0].dynamic == 'true');
r = items(call(c, [ '/ip/hotspot/host/print', '?mac-address=02:EE:00:00:00:01' ]));
check('/ip/hotspot/host/print shows the host authorized', r[0]?.authorized == 'true');
r = call(c, [ '/ip/hotspot/active/remove', `=.id=${id}`, '.tag=7' ]);
check('/ip/hotspot/active/remove disconnects (tag echoed)', r[0]?.type == '!done' && r[0]?.attrs?.['.tag=7']);
check('session gone', !length(filter(conn.call('wrthotspot', 'sessions', {})?.sessions ?? [], (s) => s.user == 'apiuser')));
r = call(c, [ '/ip/hotspot/active/remove', '=.id=*FFFF' ]);
check('removing an unknown session trapped', r[0]?.type == '!trap');

r = call(c, [ '/ip/hotspot/user/remove', '=numbers=apiuser' ]);
check('/ip/hotspot/user/remove', r[0]?.type == '!done' && !conn.call('wrthotspot', 'user_list', { search: 'apiuser' })?.users?.[0]);

r = call(c, [ '/quit' ]);
check('/quit ends the session', r[0]?.type == '!fatal');
c.s.close();

// Pipelined password guesses: after a failed login nothing queued behind it
// may run, and the connection ends after three failures.
c = connect();
let burst = '';
for (let i = 0; i < 10; i++)
	burst += rosapi.sentence([ '/login', '=name=billing', `=password=guess${i}` ]);
burst += rosapi.sentence([ '/ip/hotspot/user/print' ]);
c.s.send(burst);
let traps = 0, rows = 0;
for (let n = 0; n < 40; n++) {
	let p = rosapi.next_sentence(c.buf);
	if (p == null) {
		let d = c.s.recv(65536);
		if (d == null || d == '')
			break;
		c.buf += d;
		continue;
	}
	c.buf = substr(c.buf, p[1]);
	if (p[0][0] == '!trap') traps++;
	if (p[0][0] == '!re') rows++;
}
check('pipelined guesses: at most 3 tries per connection', traps <= 3, `(${traps} refused)`);
check('pipelined guesses: commands behind them never run', rows == 0);
c.s.close();

// Address restriction: only the allow list may connect.
sh("uci add_list wrthotspot.global.api_allow=192.0.2.1; uci commit wrthotspot");
conn.call('wrthotspot', 'reload', {});
sleep(500);
c = connect();
r = c ? call(c, [ '/login', '=name=billing', '=password=apisecret1' ]) : [];
check('connection from outside api_allow refused', !length(r));
c?.s.close();

// Cleanup.
sh('ip -6 neigh del fd99::4:1 dev br-hstest');
sh("for o in api_enable api_user api_password api_allow; do uci -q delete wrthotspot.global.$o; done; uci commit wrthotspot");
conn.call('wrthotspot', 'reload', {});

print(`\nRESULT: ${pass} passed, ${fail} failed\n`);
exit(fail ? 1 : 0);
