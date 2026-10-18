// Per-user rate limits (MikroTik rate-limit syntax).
//
// tc backend (preferred): one HTB tree per hotspot device. Downloads are
// shaped on the device's egress, uploads on an IFB device that receives the
// device's ingress. Every session gets one class per direction, selected by
// a flower filter on the client's MAC - so IPv4 and IPv6 are shaped alike and
// no conntrack marks are involved. Leaves are fq_codel.
//
// Burst follows MikroTik: burst-rate is allowed while the average rate over
// burst-time stays below burst-threshold. hotspotd evaluates that average on
// every poll and switches the class ceiling (see burst_allowed()).
//
// nft backend (fallback when tc/HTB are missing): per-session nftables limit
// objects that police (drop) above the rate. No burst, priority or min-rate.
'use strict';

import * as fs from 'fs';
import { run, write_atomic, log } from 'wrthotspot.util';

const UNITS = { '': 1, k: 1000, m: 1000000, g: 1000000000 };

// "512k", "1.5M", "2000000", "10G" -> bits/s (0 = unlimited)
export function parse_rate(v) {
	if (v == null || v === '' || v === '0')
		return 0;

	let m = match(lc(trim(`${v}`)), /^([0-9]+(\.[0-9]+)?)([kmg]?)(bps|bit)?$/);
	return m ? int(+m[1] * UNITS[m[3]]) : null;
};

function pair(s, conv) {
	if (s == null)
		return [ null, null ];

	let p = split(s, '/');
	let a = conv(p[0]), b = conv(p[1] ?? p[0]);

	return [ a, b ];
}

// MikroTik: "rx[/tx] [rx-burst[/tx-burst] [rx-thr[/tx-thr] [rx-time[/tx-time] [prio] [rx-min[/tx-min]]]]]"
// rx = what the router receives from the client (upload), tx = download.
// -> { rx: dir, tx: dir } with dir = { rate, burst_rate, burst_threshold, burst_time, priority, min_rate }
function parse_rate_limit_uncached(s) {
	let f = split(trim(`${s}`), /[ \t]+/);

	if (length(f) > 6)
		return null;

	let rate = pair(f[0], parse_rate);
	let burst = pair(f[1], parse_rate);
	let thr = pair(f[2], parse_rate);
	let tm = pair(f[3], (x) => (x != null && match(x, /^[0-9]+s?$/)) ? int(x) : null);
	let prio = (f[4] != null) ? int(f[4]) : 8;
	let min = pair(f[5], parse_rate);

	if (rate[0] == null || rate[1] == null || (f[1] && (burst[0] == null || burst[1] == null)) ||
	    (f[2] && (thr[0] == null || thr[1] == null)) || (f[3] && (tm[0] == null || tm[1] == null)) ||
	    prio < 1 || prio > 8 || (f[5] && (min[0] == null || min[1] == null)))
		return null;

	let dir = (i) => ({
		rate: rate[i],
		burst_rate: burst[i] ?? 0,
		// MikroTik: threshold defaults to the rate when burst is set without one.
		burst_threshold: thr[i] ?? rate[i],
		burst_time: tm[i] ?? 1,
		priority: prio,
		min_rate: min[i] ?? 0,
	});

	return { rx: dir(0), tx: dir(1) };
};

// Parsed limits are cached: every poll asks for every session's limit.
let parsed = {}, parsed_n = 0;

export function parse_rate_limit(s) {
	if (s == null || trim(`${s}`) == '')
		return null;

	if (exists(parsed, s))
		return parsed[s];

	if (++parsed_n > 256) {
		parsed = {};
		parsed_n = 1;
	}

	return (parsed[s] = parse_rate_limit_uncached(s));
};


// Burst is allowed while the average over the last burst_time seconds is
// below the threshold (and burst is configured and faster than the rate).
export function burst_allowed(d, avg_bps) {
	return d.burst_rate > d.rate && d.rate > 0 && avg_bps < d.burst_threshold;
};

// The ceiling a direction should have right now.
export function effective_ceil(d, bursting) {
	return (bursting && d.burst_rate > d.rate) ? d.burst_rate : d.rate;
};

// Average bits/s over the window from samples [ [ t, bytes ], ... ] (oldest first).
export function window_avg(samples, window, now) {
	let last = samples[length(samples) - 1];

	if (!last)
		return 0;

	let first = last;
	for (let s in samples)
		if (now - s[0] <= window) {
			first = s;
			break;
		}

	// Like MikroTik, a window not yet full counts its missing part as idle.
	let dt = max(last[0] - first[0], window);
	return (dt > 0) ? int((last[1] - first[1]) * 8 / dt) : 0;
};

/* ---------- tc backend ---------- */

export const LEAF = 'fq_codel flows 64 limit 300 memory_limit 512Kb';

function hx(n) {
	return sprintf('%x', n);
}

function quantum(bps) {
	// HTB wants quantum >= MTU and not huge; rate/8/10 clamped.
	return max(1600, min(int(bps / 80), 60000));
}

export function tc_available() {
	return run('tc -V').code == 0 && (fs.stat('/sys/module/sch_htb') || run('modprobe sch_htb').code == 0) &&
		(fs.stat('/sys/module/cls_flower') || run('modprobe cls_flower').code == 0);
};

export function tc_backend(state_dir) {
	let devs = {};		// dev -> { ifb, cap }
	let self;

	// Between begin() and commit() commands are collected and run as one
	// tc process (re-applying thousands of sessions after a restart).
	let pending = null;

	function batch(lines) {
		if (pending != null) {
			push(pending, ...lines);
			return null;
		}

		if (!length(lines))
			return null;

		let path = `${state_dir}/tc.batch`;
		write_atomic(path, join('\n', lines) + '\n');

		let r = run(`tc -force -batch ${path}`);
		fs.unlink(path);

		return (r.code == 0) ? null : trim(r.out);
	}

	function tree(dev, cap) {
		let c = `${cap}bit`;

		return [
			`qdisc add dev ${dev} root handle 1: htb default ffff`,
			`class add dev ${dev} parent 1: classid 1:1 htb rate ${c} ceil ${c} quantum 60000`,
			// Unshaped traffic (unauthenticated, bypassed, unlimited users).
			`class add dev ${dev} parent 1:1 classid 1:ffff htb rate ${int(cap / 100)}bit ceil ${c} prio 7 quantum 60000`,
			`qdisc add dev ${dev} parent 1:ffff fq_codel`,
		];
	}

	self = {
		name: 'tc',

		// devices: [ dev ]; cap: bits/s of the root classes.
		setup: function(devices, cap) {
			self.teardown();

			let i = 0;
			let lines = [];

			for (let dev in sort(devices)) {
				let ifb = `hsifb${i++}`;

				run(`ip link add ${ifb} type ifb 2>/dev/null; ip link set ${ifb} up`);

				push(lines,
					`qdisc del dev ${dev} root`,
					`qdisc del dev ${dev} ingress`,
					...tree(dev, cap), ...tree(ifb, cap),
					`qdisc add dev ${dev} handle ffff: ingress`,
					`filter add dev ${dev} parent ffff: protocol all prio 1 matchall action mirred egress redirect dev ${ifb}`);

				devs[dev] = { ifb, cap };
			}

			let err = batch(lines);

			// "qdisc del" of absent qdiscs fails harmlessly; check the result instead.
			for (let dev, d in devs)
				if (!self.healthy(dev))
					return `tc setup failed on ${dev}: ${err}`;

			return null;
		},

		healthy: function(dev) {
			let d = devs[dev];

			return d && index(run(`tc qdisc show dev ${dev}`).out, 'htb 1:') >= 0 &&
				index(run(`tc qdisc show dev ${d.ifb}`).out, 'htb 1:') >= 0;
		},

		devices: () => keys(devs),

		begin: function() {
			pending = [];
		},

		commit: function() {
			let lines = pending ?? [];
			pending = null;
			return batch(lines);
		},

		// limits: parse_rate_limit() result; ceil = { rx, tx } current ceilings.
		set_session: function(dev, slot, mac, limits, ceil) {
			let d = devs[dev];

			if (!d || slot >= 0xfffe)
				return 'no shaper on device';

			let lines = [];
			let cls = hx(slot), leaf = hx(slot + 1);

			for (let side in [ [ dev, 'tx', 'dst_mac' ], [ d.ifb, 'rx', 'src_mac' ] ]) {
				let l = limits[side[1]];
				let max_bps = ceil?.[side[1]] ?? l.rate;
				let rate = l.min_rate ? min(l.min_rate, max_bps) : max_bps;

				if (!max_bps) {
					// Unlimited in this direction: no class, default class applies.
					push(lines, `filter del dev ${side[0]} parent 1: protocol all prio 10 handle 0x${cls} flower`);
					continue;
				}

				push(lines,
					`class replace dev ${side[0]} parent 1:1 classid 1:${cls} htb rate ${rate}bit ceil ${max_bps}bit prio ${l.priority - 1} quantum ${quantum(max_bps)}`);

				// fq_codel leaf: measured through HTB at 512k-20M it delivers ~95%
				// of the rate as TCP goodput (the header overhead), on v4 and v6.
				// Sized for one device: the default 1024 flow slots cost ~70 KiB
				// of kernel memory per qdisc, which ran a 256 MB router out of
				// memory at ~900 shaped users; 64 slots and a 300-packet / 512 KiB
				// queue keep it at a few KiB per user.
				push(lines, `qdisc replace dev ${side[0]} parent 1:${cls} handle ${leaf}: ${LEAF}`);

				push(lines,
					`filter replace dev ${side[0]} parent 1: protocol all prio 10 handle 0x${cls} flower ${side[2]} ${mac} classid 1:${cls}`);
			}

			return batch(lines);
		},

		del_session: function(dev, slot) {
			let d = devs[dev];

			if (!d)
				return null;

			let cls = hx(slot);
			let lines = [];

			for (let x in [ dev, d.ifb ]) {
				push(lines,
					`filter del dev ${x} parent 1: protocol all prio 10 handle 0x${cls} flower`,
					`class del dev ${x} classid 1:${cls}`);
			}

			batch(lines);
			return null;
		},

		// Also cleans `extra` devices: trees left by an earlier daemon run
		// (e.g. before switching to the nft backend) are recognised by their
		// ingress redirect to an hsifb device.
		teardown: function(extra) {
			for (let dev, d in devs) {
				run(`tc qdisc del dev ${dev} root 2>/dev/null; tc qdisc del dev ${dev} ingress 2>/dev/null`);
				run(`ip link del ${d.ifb} 2>/dev/null`);
			}

			for (let dev in extra ?? [])
				if (index(run(`tc filter show dev ${dev} ingress`).out, 'hsifb') >= 0)
					run(`tc qdisc del dev ${dev} root 2>/dev/null; tc qdisc del dev ${dev} ingress 2>/dev/null`);

			// Also IFBs of a previous daemon run.
			for (let n in (fs.lsdir('/sys/class/net') ?? []))
				if (match(n, /^hsifb[0-9]+$/))
					run(`ip link del ${n}`);

			devs = {};
		},
	};

	return self;
};

// Per-direction nftables limit for the nft backend, in bytes/s. The kernel
// already sizes a byte-mode bucket at one second of rate plus `burst`, which
// is plenty of slack for TCP, so the extra burst is just a few packets.
export function nft_limit(bps) {
	if (!bps)
		return null;

	return { rate: max(1, int(bps / 8)), burst: 4500 };
};
