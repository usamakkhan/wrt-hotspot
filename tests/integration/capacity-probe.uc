// Measures what users, hosts and sessions cost in RAM, to calibrate the
// capacity tiers in capacity.uc. Run on a test router after
// `netns-test.sh keep`:   ucode capacity-probe.uc [N]
'use strict';

import * as ubus from 'ubus';
import * as fs from 'fs';

let N = int(ARGV[0] ?? 1000);
let conn = ubus.connect(null, 5);

function sh(cmd) {
	let p = fs.popen(`${cmd} 2>&1`, 'r');
	let out = p.read('all');
	p.close();
	return trim(out ?? '');
}

function hs(method, args) {
	return conn.call('wrthotspot', method, args ?? {});
}

function avail() {
	sh('sync; echo 3 > /proc/sys/vm/drop_caches');
	sleep(1500);
	return int(sh("awk '/MemAvailable/{print $2}' /proc/meminfo"));
}

function rss() {
	return hs('status')?.rss_kb ?? 0;
}

function mac(i) {
	return sprintf('02:cc:00:00:%02x:%02x', (i >> 8) & 0xff, i & 0xff);
}

function per(label, before, after, rss0, rss1) {
	printf('  %-34s total %6d KiB  per item %5.1f KiB  (daemon %5.1f KiB)\n',
		label, before - after, (before - after) / N, (rss1 - rss0) / N);
}

function neigh(op) {
	let b = '';
	for (let i = 1; i <= N; i++)
		b += (op == 'add')
			? sprintf('neigh replace fd99::2:%x lladdr %s dev br-hstest nud permanent\n', i, mac(i))
			: sprintf('neigh del fd99::2:%x dev br-hstest\n', i);
	fs.writefile('/tmp/cap-neigh.batch', b);
	sh('ip -6 -batch /tmp/cap-neigh.batch');
	fs.unlink('/tmp/cap-neigh.batch');
}

function wait_hosts(n) {
	for (let t = 0; t < 300 && hs('status').hosts < n; t++)
		sleep(100);
}

function login_all(codes) {
	for (let i = 1; i <= N; i++)
		hs('login', { mac: mac(i), method: 'http-pap', username: codes[i - 1], password: codes[i - 1] });
	sleep(12000);	// one poll: counters, shaper classes
}

function logout_all() {
	for (let i = 1; i <= N; i++)
		hs('logout', { mac: mac(i), cause: 'admin-reset' });
	sleep(3000);
}

function vouchers(profile) {
	let codes = [];
	for (let left = N; left > 0; left -= 1000)
		for (let v in hs('voucher_create', { profile, count: min(left, 1000), length: 10, charset: 'alnum', comment: 'capacity probe' }).vouchers)
			push(codes, v.name);
	return codes;
}

function revoke() {
	for (let b in hs('voucher_batches').batches)
		if (b.comment == 'capacity probe')
			hs('voucher_revoke', { batch: b.batch, all: true });
}

sh("uci set wrthotspot.capfree=user_profile; uci set wrthotspot.capfree.shared_users=1; uci set wrthotspot.capshaped=user_profile; uci set wrthotspot.capshaped.shared_users=1; uci set wrthotspot.capshaped.rate_limit='2M/10M'; uci commit wrthotspot");
hs('reload');
sleep(2000);

printf('== capacity probe, N = %d (MemTotal %s KiB, shaper %s, RADIUS %s)\n', N,
	sh("awk '/MemTotal/{print $2}' /proc/meminfo"), hs('status').shaper, hs('status').radius ? 'loaded' : 'absent');
printf('  daemon RSS at idle                 %d KiB\n', rss());

let a0 = avail(), r0 = rss();
let free_codes = vouchers('capfree');
let a1 = avail(), r1 = rss();
per('local user accounts (vouchers)', a0, a1, r0, r1);

neigh('add');
wait_hosts(N);
let a2 = avail(), r2 = rss();
per('hosts (neighbor + daemon entry)', a1, a2, r1, r2);

login_all(free_codes);
let a3 = avail(), r3 = rss();
printf('  sessions online: %d\n', hs('status').sessions);
per('unshaped sessions', a2, a3, r2, r3);
logout_all();
revoke();

let shaped_codes = vouchers('capshaped');
let a4 = avail(), r4 = rss();
login_all(shaped_codes);
let a5 = avail(), r5 = rss();
printf('  sessions online: %d\n', hs('status').sessions);
per('shaped sessions (tc HTB)', a4, a5, r4, r5);
logout_all();
revoke();

neigh('del');
sh('uci -q delete wrthotspot.capfree; uci -q delete wrthotspot.capshaped; uci commit wrthotspot');
hs('reload');
printf('  cleanup: sessions %d, users %d\n', hs('status').sessions, hs('status').users);
