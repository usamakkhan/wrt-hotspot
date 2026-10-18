// Control-plane load test: N simulated clients logged in at once.
// Run on the router after `netns-test.sh keep` (needs br-hstest / server hstest):
//   ucode load-test.uc [N] [rate-limit]
// Clients are permanent IPv6 neighbor entries with their own MAC on
// br-hstest, so hotspotd learns them through rtnetlink like real hosts.
'use strict';

import * as ubus from 'ubus';
import * as fs from 'fs';

let N = int(ARGV[0] ?? 2000);
let RATE = ARGV[1] ?? '2M/10M';
let conn = ubus.connect(null, 5);	// 5 s call timeout: restarts must not hang the test

function ms() {
	let c = clock(true);
	return c[0] * 1000 + c[1] / 1000000;
}

function sh(cmd) {
	let p = fs.popen(`${cmd} 2>&1`, 'r');
	let out = p.read('all');
	p.close();
	return trim(out ?? '');
}

function hs(method, args) {
	return conn.call('wrthotspot', method, args ?? {});
}

function mac(i) {
	return sprintf('02:aa:00:00:%02x:%02x', (i >> 8) & 0xff, i & 0xff);
}

function pct(list, p) {
	let s = sort([ ...list ], (a, b) => a - b);
	return s[min(length(s) - 1, int(length(s) * p))];
}

function avg(l) {
	let sum = 0;
	for (let v in l)
		sum += v;
	return length(l) ? sum / length(l) : 0;
}

function report(name, value) {
	printf('  %-46s %s\n', name, value);
}

function status() {
	return hs('status');
}

print(`== load test: ${N} clients, rate limit ${RATE}\n`);

// Profile for the load users (rate-limited: worst case for tc).
sh(`uci set wrthotspot.loadprof=user_profile; uci set wrthotspot.loadprof.rate_limit='${RATE}'; uci set wrthotspot.loadprof.keepalive_timeout=0; uci set wrthotspot.loadprof.shared_users=1; uci commit wrthotspot`);
hs('reload');
for (let tries = 0; tries < 100 && !status(); tries++)
	sleep(200);

let base = status();
report('baseline: daemon RSS', `${base.rss_kb} KiB`);

// 1. Simulated hosts.
let t = ms();
let batch = '';
for (let i = 1; i <= N; i++)
	batch += sprintf('neigh replace fd99::1:%x lladdr %s dev br-hstest nud permanent\n', i, mac(i));
fs.writefile('/tmp/load-neigh.batch', batch);
sh('ip -6 -batch /tmp/load-neigh.batch');

let learned = 0;
for (let tries = 0; tries < 300; tries++) {
	learned = status().hosts;
	if (learned >= N)
		break;
	sleep(100);
}
report('hosts learned via rtnetlink', `${learned} in ${int(ms() - t)} ms`);

// 2. Vouchers (batches of up to 1000).
t = ms();
let codes = [];
for (let left = N; left > 0; left -= 1000) {
	let r = hs('voucher_create', { profile: 'loadprof', count: min(left, 1000), length: 10, charset: 'alnum', comment: 'load test' });
	if (!r?.ok)
		die(`voucher_create failed: ${sprintf('%J', r)}\n`);
	for (let v in r.vouchers)
		push(codes, v.name);
}
report('vouchers created', `${length(codes)} in ${int(ms() - t)} ms`);

// 3. Logins, one after the other (worst case for a single-threaded daemon).
let lat = [], failed = 0;
t = ms();
for (let i = 1; i <= N; i++) {
	let t1 = ms();
	let r = hs('login', { mac: mac(i), method: 'http-pap', username: codes[i - 1], password: codes[i - 1] });
	push(lat, ms() - t1);
	if (!r?.ok)
		failed++;
}
let total = ms() - t;
report('logins', sprintf('%d ok, %d failed in %.1f s (%.0f/s)', N - failed, failed, total / 1000, N / (total / 1000)));
report('login latency p50 / p95 / max', sprintf('%.1f / %.1f / %.1f ms', pct(lat, 0.5), pct(lat, 0.95), pct(lat, 1)));
report('login latency first 100 / last 100 (avg)', sprintf('%.1f / %.1f ms', avg(slice(lat, 0, 100)), avg(slice(lat, -100))));

// 4. Steady state.
sleep(12000);
let st = status();
report('sessions', st.sessions);
report('daemon RSS with all sessions', `${st.rss_kb} KiB (+${st.rss_kb - base.rss_kb} KiB)`);
report('poll duration (last / max)', `${st.poll_ms} / ${st.poll_max_ms} ms`);
report('nft elements in auth_mac', sh("nft -j list set inet wrthotspot auth_mac | jsonfilter -e '@.nftables[1].set.elem[*]' | wc -l"));
report('nft named counters', sh("nft list counters table inet wrthotspot | grep -c 'counter c'"));
report('tc classes on br-hstest / IFB', sprintf('%s / %s', sh("tc class show dev br-hstest | grep -c 'htb 1:'"), sh("tc class show dev hsifb0 | grep -c 'htb 1:'")));
report('tc filters on br-hstest', sh("tc filter show dev br-hstest | grep -c 'flower'"));
report('uhttpd portal RSS', sh("grep VmRSS /proc/$(pgrep -f 'uhttpd -f -D -p 0.0.0.0:8002' | head -1)/status | awk '{print $2\" KiB\"}'"));
report('free memory', sh("awk '/MemAvailable/{print $2\" KiB\"}' /proc/meminfo"));

// Lists come in pages that fit a ubus message.
let pg = hs('sessions', { limit: 1000 });
report('sessions list page / total', `${length(pg?.sessions ?? [])} / ${pg?.total}`);

// Daemon restart with every session: they must all come back, once.
t = ms();
sh('/etc/init.d/wrthotspot stop');
let t_stop = ms() - t;
sh('/etc/init.d/wrthotspot start');
let t_start = ms() - t - t_stop;
report('daemon stop / start commands', sprintf('%d / %d ms', t_stop, t_start));
for (let tries = 0; tries < 600; tries++) {
	sleep(100);
	if (status()?.sessions >= N)
		break;
}
report('daemon restart: sessions back', sprintf('%d in %d ms', status()?.sessions, int(ms() - t)));
sleep(6000);
report('sessions 6 s after restart (no duplicates)', status()?.sessions);

// 5. Full dataplane rebuild with every session (as after `fw4 flush`).
sh('nft delete table inet wrthotspot');
t = ms();
for (let tries = 0; tries < 400; tries++) {
	if (sh('nft list chain inet wrthotspot forward >/dev/null 2>&1; echo $?') == '0')
		break;
	sleep(50);
}
report('table restored after deletion', `${int(ms() - t)} ms (includes up to one poll interval)`);
sleep(3000);
st = status();
report('rebuild: nft transaction time / ruleset size', `${st.rebuild_ms} ms / ${st.rebuild_rules_kb} KiB`);
report('sessions after rebuild', st.sessions);

// 6. Log everybody out, one by one.
lat = [];
t = ms();
for (let i = 1; i <= N; i++) {
	let t1 = ms();
	hs('logout', { mac: mac(i), cause: 'admin-reset' });
	push(lat, ms() - t1);
}
total = ms() - t;
report('logouts', sprintf('%d in %.1f s (%.0f/s)', N, total / 1000, N / (total / 1000)));
report('logout latency p50 / p95 / max', sprintf('%.1f / %.1f / %.1f ms', pct(lat, 0.5), pct(lat, 0.95), pct(lat, 1)));
report('tc classes left', sh("tc class show dev br-hstest | grep -c 'htb 1:'"));

// Cleanup.
for (let b in hs('voucher_batches').batches)
	if (b.comment == 'load test')
		hs('voucher_revoke', { batch: b.batch, all: true });

let del = '';
for (let i = 1; i <= N; i++)
	del += sprintf('neigh del fd99::1:%x dev br-hstest\n', i);
fs.writefile('/tmp/load-neigh.batch', del);
sh('ip -6 -batch /tmp/load-neigh.batch');
fs.unlink('/tmp/load-neigh.batch');
sh('uci -q delete wrthotspot.loadprof; uci commit wrthotspot');
hs('reload');
report('cleanup: sessions / users left', sprintf('%d / %d', status().sessions, status().users));
