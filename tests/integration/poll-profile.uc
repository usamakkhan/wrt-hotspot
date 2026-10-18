// Where does a poll's time go with many sessions? Run on the router while
// sessions are loaded:  ucode -L '/usr/share/ucode/*.uc' poll-profile.uc
'use strict';

import * as fs from 'fs';
import * as nft from 'wrthotspot.nft';

function ms() {
	let c = clock(true);
	return c[0] * 1000 + c[1] / 1000000;
}

function step(name, fn) {
	let t = ms();
	let r = fn();
	printf('  %-40s %8.1f ms\n', name, ms() - t);
	return r;
}

let raw = step('nft -j list counters (process + dump)', () => {
	let p = fs.popen('nft -j list counters table inet wrthotspot', 'r');
	let out = p.read('all');
	p.close();
	return out;
});
printf('  %-40s %8d KiB\n', 'counter dump size', length(raw) / 1024);

let data = step('json() parse', () => json(raw));
step('read_counters() total', () => nft.read_counters());

let st = json(fs.readfile('/tmp/wrthotspot/sessions.json') ?? '{}');
printf('  %-40s %8d\n', 'sessions in checkpoint', length(st.sessions ?? []));
step('checkpoint serialise (sprintf %J)', () => sprintf('%J', st));

let p2 = fs.popen('nft -j list counters table inet wrthotspot >/dev/null', 'r');
step('nft dump alone, output discarded', () => { p2.read('all'); p2.close(); });
step('plain-text counter dump', () => {
	let p = fs.popen('nft list counters table inet wrthotspot', 'r');
	let out = p.read('all');
	p.close();
	return out;
});
