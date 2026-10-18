// nftables dataplane: one table `inet wrthotspot`, owned entirely by hotspotd.
//
// Client identity is the MAC address. On the first packet of every connection
// from a hotspot interface, ct mark is set to the client's session slot
// (slot << 16, so the low 16 bits stay free for mwan3 & co). Every later
// decision - both directions, IPv4 and IPv6 - keys on that ct mark, so SLAAC
// privacy addresses need no extra bookkeeping.
//
// Our chains only drop, reject, redirect or count. Forwarding itself is still
// fw4's job, because an accept here cannot override a drop in fw4.
'use strict';

import * as fs from 'fs';
import { run, write_atomic, log } from 'wrthotspot.util';

export const TABLE = 'inet wrthotspot';
export const MARK_MASK = '0xffff0000';
export const MAX_SLOT = 65535;

export function slot_mark(slot) {
	return slot << 16;
};

function list(items) {
	return join(', ', items);
}

function elements(items) {
	return length(items) ? `\t\telements = { ${list(items)} }\n` : '';
}

function q(s) {
	return `"${s}"`;
}

function set_def(name, type, flags, elems, extra) {
	let r = `\tset ${name} {\n\t\ttype ${type}\n`;

	if (flags)
		r += `\t\tflags ${flags}\n`;

	if (extra)
		r += `\t\t${extra}\n`;

	return r + elements(elems ?? []) + '\t}\n';
}

// "iifname { ... } " for a server-scoped entry, '' for all servers, null for
// a server that currently has no device (match nothing rather than everything).
function iif_match(server, devices) {
	if (!server || server == 'all')
		return '';

	let devs = filter(keys(devices), (d) => devices[d] == server);
	return length(devs) ? `iifname { ${list(map(devs, q))} } ` : null;
}

function binding_matches(b, devices) {
	let iif = iif_match(b.server, devices);

	if (iif == null)
		return [];

	let ip = b.address ? `${(b.address.family == 6) ? 'ip6' : 'ip'} saddr ${b.address.cidr}` : null;

	if (b.mac && ip)
		return [ `${iif}ether saddr ${b.mac} ${ip}` ];

	return [ `${iif}${b.mac ? `ether saddr ${b.mac}` : ip}` ];
}

export function wg_matches(e, devices) {
	let iif = iif_match(e.server, devices);

	if (iif == null)
		return [];

	let l4 = '';
	if (e.protocol && e.dst_port)
		l4 = ` meta l4proto ${e.protocol} th dport ${e.dst_port}`;
	else if (e.protocol)
		l4 = ` meta l4proto ${e.protocol}`;

	let out = [];

	if (e.host) {
		push(out, `${iif}ip daddr @wgh${e.idx}_4${l4}`);
		push(out, `${iif}ip6 daddr @wgh${e.idx}_6${l4}`);
	}

	let v4 = map(filter(e.prefixes, (p) => p.family == 4), (p) => p.cidr);
	let v6 = map(filter(e.prefixes, (p) => p.family == 6), (p) => p.cidr);

	if (length(v4))
		push(out, `${iif}ip daddr { ${list(v4)} }${l4}`);

	if (length(v6))
		push(out, `${iif}ip6 daddr { ${list(v6)} }${l4}`);

	if (!e.host && !length(e.prefixes))
		push(out, trim(`${iif}${l4}`));

	return out;
};

// state: {
//   ifaces: [dev], devices: { dev: server }, port,
//   sessions: [ { slot, mac } ],
//   bindings: [ { type, server, mac, address: { family, cidr } } ],
//   walled_garden: [ { idx, action, server, host, prefixes, protocol, dst_port } ],
//   wg_ttl: seconds
// }
export function ruleset(state) {
	let ifaces = map(state.ifaces, q);
	let devices = state.devices ?? {};
	let sessions = state.sessions ?? [];
	let marks = map(sessions, (s) => slot_mark(s.slot));
	let wg = state.walled_garden ?? [];
	let r = '';

	// Server-wide bindings go into sets (O(1) per packet); server-scoped ones
	// become explicit rules.
	let b = {
		bypass: { mac: [], v4: [], v6: [], macv4: [], macv6: [], rules: [] },
		block: { mac: [], v4: [], v6: [], macv4: [], macv6: [], rules: [] },
	};

	for (let x in state.bindings ?? []) {
		let t = (x.type == 'bypassed') ? b.bypass : (x.type == 'blocked') ? b.block : null;

		if (!t)
			continue;

		if (x.server && x.server != 'all')
			push(t.rules, ...binding_matches(x, devices));
		else if (x.mac && x.address)
			push((x.address.family == 6) ? t.macv6 : t.macv4, `${x.mac} . ${x.address.cidr}`);
		else if (x.mac)
			push(t.mac, x.mac);
		else
			push((x.address.family == 6) ? t.v6 : t.v4, x.address.cidr);
	}

	r += `table ${TABLE}\n`;
	r += `delete table ${TABLE}\n`;
	r += `table ${TABLE} {\n`;

	r += set_def('hs_ifaces', 'ifname', null, ifaces);
	r += set_def('auth_mac', 'ether_addr', null, map(sessions, (s) => s.mac));
	r += set_def('active', 'mark', null, marks);
	r += `\tmap mac2id {\n\t\ttype ether_addr : mark\n${elements(map(sessions, (s) => `${s.mac} : ${slot_mark(s.slot)}`))}\t}\n`;

	for (let kind in [ 'bypass', 'block' ]) {
		let t = b[kind];
		r += set_def(`${kind}_mac`, 'ether_addr', null, t.mac);
		r += set_def(`${kind}4`, 'ipv4_addr', 'interval', t.v4);
		r += set_def(`${kind}6`, 'ipv6_addr', 'interval', t.v6);
		r += set_def(`${kind}_macip4`, 'ether_addr . ipv4_addr', null, t.macv4);
		r += set_def(`${kind}_macip6`, 'ether_addr . ipv6_addr', null, t.macv6);
	}

	// One pair of sets per walled-garden host, filled by dnsmasq nftset= and
	// by hotspotd's own resolver.
	for (let e in wg) {
		if (e.host) {
			r += set_def(`wgh${e.idx}_4`, 'ipv4_addr', 'timeout', null, `timeout ${state.wg_ttl ?? 3600}s`);
			r += set_def(`wgh${e.idx}_6`, 'ipv6_addr', 'timeout', null, `timeout ${state.wg_ttl ?? 3600}s`);
		}
	}

	for (let s in sessions)
		r += `\tcounter cu_${s.slot} { }\n\tcounter cd_${s.slot} { }\n`;

	r += `\tmap cnt_up {\n\t\ttype mark : counter\n${elements(map(sessions, (s) => `${slot_mark(s.slot)} : "cu_${s.slot}"`))}\t}\n`;
	r += `\tmap cnt_down {\n\t\ttype mark : counter\n${elements(map(sessions, (s) => `${slot_mark(s.slot)} : "cd_${s.slot}"`))}\t}\n`;

	// nft shaper backend: per-session policers ({ up, down } = { rate, burst } in bytes).
	let lim = { up: [], down: [] };

	for (let s in sessions) {
		for (let d in [ 'up', 'down' ]) {
			let l = s.lim?.[d];

			if (l) {
				r += `\tlimit l${substr(d, 0, 1)}_${s.slot} { rate over ${l.rate} bytes/second burst ${l.burst} bytes }\n`;
				push(lim[d], `${slot_mark(s.slot)} : "l${substr(d, 0, 1)}_${s.slot}"`);
			}
		}
	}

	r += `\tmap lim_up {\n\t\ttype mark : limit\n${elements(lim.up)}\t}\n`;
	r += `\tmap lim_down {\n\t\ttype mark : limit\n${elements(lim.down)}\t}\n`;

	r += `\tchain blocked {\n`;
	r += `\t\tether saddr @block_mac drop\n`;
	r += `\t\tip saddr @block4 drop\n`;
	r += `\t\tip6 saddr @block6 drop\n`;
	r += `\t\tether saddr . ip saddr @block_macip4 drop\n`;
	r += `\t\tether saddr . ip6 saddr @block_macip6 drop\n`;
	for (let m in b.block.rules)
		r += `\t\t${m} drop\n`;
	r += `\t}\n`;

	// accept ends *our* base chain only; fw4 still decides about forwarding.
	r += `\tchain bypassed {\n`;
	r += `\t\tether saddr @bypass_mac accept\n`;
	r += `\t\tip saddr @bypass4 accept\n`;
	r += `\t\tip6 saddr @bypass6 accept\n`;
	r += `\t\tether saddr . ip saddr @bypass_macip4 accept\n`;
	r += `\t\tether saddr . ip6 saddr @bypass_macip6 accept\n`;
	for (let m in b.bypass.rules)
		r += `\t\t${m} accept\n`;
	r += `\t}\n`;

	// Walled garden: deny entries return to the caller (so the redirect or
	// reject that follows applies), allow entries accept.
	r += `\tchain wg_check {\n`;
	for (let e in filter(wg, (e) => e.action == 'deny'))
		for (let m in wg_matches(e, devices))
			r += `\t\t${m} return\n`;
	for (let e in filter(wg, (e) => e.action == 'allow'))
		for (let m in wg_matches(e, devices))
			r += `\t\t${m} accept\n`;
	r += `\t}\n`;

	// Tag new connections with the client's slot. A MAC without a session
	// misses the map lookup and keeps ct mark 0.
	r += `\tchain mark_in {\n`;
	r += `\t\ttype filter hook prerouting priority mangle - 10; policy accept;\n`;
	r += `\t\tiifname @hs_ifaces ct state new ct mark set ether saddr map @mac2id\n`;
	r += `\t}\n`;

	// Blocked hosts may not even reach the portal or DNS.
	r += `\tchain input {\n`;
	r += `\t\ttype filter hook input priority filter - 10; policy accept;\n`;
	r += `\t\tiifname @hs_ifaces jump blocked\n`;
	r += `\t}\n`;

	// Unauthenticated clients: DNS to the router, HTTP to the portal.
	r += `\tchain dstnat {\n`;
	r += `\t\ttype nat hook prerouting priority dstnat - 5; policy accept;\n`;
	r += `\t\tiifname != @hs_ifaces return\n`;
	r += `\t\tether saddr @auth_mac return\n`;
	r += `\t\tjump bypassed\n`;
	r += `\t\tfib daddr type local return\n`;
	r += `\t\tjump wg_check\n`;
	r += `\t\tmeta l4proto { tcp, udp } th dport 53 redirect to :53\n`;
	r += `\t\ttcp dport 80 redirect to :${state.port}\n`;
	r += `\t}\n`;

	r += `\tchain forward {\n`;
	r += `\t\ttype filter hook forward priority filter - 10; policy accept;\n`;
	r += `\t\tiifname @hs_ifaces jump from_client\n`;
	r += `\t\toifname @hs_ifaces jump to_client\n`;
	r += `\t}\n`;

	r += `\tchain from_client {\n`;
	r += `\t\tjump blocked\n`;
	r += `\t\tjump bypassed\n`;
	r += `\t\tct mark and ${MARK_MASK} != @active jump unauth\n`;
	r += `\t\tcounter name ct mark and ${MARK_MASK} map @cnt_up\n`;
	r += `\t\tlimit name ct mark and ${MARK_MASK} map @lim_up drop\n`;
	r += `\t}\n`;

	r += `\tchain to_client {\n`;
	r += `\t\tct mark and ${MARK_MASK} != @active return\n`;
	r += `\t\tcounter name ct mark and ${MARK_MASK} map @cnt_down\n`;
	r += `\t\tlimit name ct mark and ${MARK_MASK} map @lim_down drop\n`;
	r += `\t}\n`;

	r += `\tchain unauth {\n`;
	r += `\t\tjump wg_check\n`;
	r += `\t\tmeta l4proto tcp reject with tcp reset\n`;
	r += `\t\treject with icmpx admin-prohibited\n`;
	r += `\t}\n`;

	r += `}\n`;

	return r;
};

export function session_add_cmds(slot, mac) {
	let m = slot_mark(slot);

	return [
		`add counter ${TABLE} cu_${slot}`,
		`add counter ${TABLE} cd_${slot}`,
		`add element ${TABLE} cnt_up { ${m} : "cu_${slot}" }`,
		`add element ${TABLE} cnt_down { ${m} : "cd_${slot}" }`,
		`add element ${TABLE} active { ${m} }`,
		`add element ${TABLE} mac2id { ${mac} : ${m} }`,
		`add element ${TABLE} auth_mac { ${mac} }`,
	];
};

// `destroy` (nft >= 1.0.8) ignores missing objects, so one stale entry can
// never abort the whole batch.
export function session_del_cmds(slot, mac) {
	let m = slot_mark(slot);

	return [
		`destroy element ${TABLE} auth_mac { ${mac} }`,
		`destroy element ${TABLE} mac2id { ${mac} }`,
		`destroy element ${TABLE} active { ${m} }`,
		`destroy element ${TABLE} cnt_up { ${m} }`,
		`destroy element ${TABLE} cnt_down { ${m} }`,
		`destroy counter ${TABLE} cu_${slot}`,
		`destroy counter ${TABLE} cd_${slot}`,
		`destroy element ${TABLE} lim_up { ${m} }`,
		`destroy element ${TABLE} lim_down { ${m} }`,
		`destroy limit ${TABLE} lu_${slot}`,
		`destroy limit ${TABLE} ld_${slot}`,
	];
};

// nft shaper backend: (re)set a session's policers. lim = { up, down } with
// { rate, burst } in bytes; either may be null (unlimited).
export function session_limit_cmds(slot, lim) {
	let m = slot_mark(slot);
	let cmds = [];

	for (let d in [ 'up', 'down' ]) {
		let n = `l${substr(d, 0, 1)}_${slot}`;

		push(cmds, `destroy element ${TABLE} lim_${d} { ${m} }`, `destroy limit ${TABLE} ${n}`);

		if (lim?.[d])
			push(cmds,
				`add limit ${TABLE} ${n} { rate over ${lim[d].rate} bytes/second burst ${lim[d].burst} bytes }`,
				`add element ${TABLE} lim_${d} { ${m} : "${n}" }`);
	}

	return cmds;
};

// Refresh resolved walled-garden addresses: destroy + add in one batch, so
// the timeout restarts without a gap.
export function wg_refresh_cmds(idx, family, addrs, ttl) {
	if (!length(addrs))
		return [];

	let set = `wgh${idx}_${family}`;

	return [
		`destroy element ${TABLE} ${set} { ${list(addrs)} }`,
		`add element ${TABLE} ${set} { ${list(map(addrs, (a) => `${a} timeout ${ttl}s`))} }`,
	];
};

// Apply a batch atomically. Returns null on success, the nft error otherwise.
export function apply(text, tmpdir) {
	let path = `${tmpdir ?? '/tmp'}/wrthotspot-batch.nft`;

	if (!write_atomic(path, text))
		return `cannot write ${path}`;

	let res = run(`nft -f ${path}`);

	if (res.code != 0) {
		log('error', 'nft batch failed: %s', trim(res.out));
		return trim(res.out) || `nft exited ${res.code}`;
	}

	fs.unlink(path);
	return null;
};

export function table_exists() {
	return run(`nft list chain ${TABLE} forward >/dev/null`).code == 0;
};

// { slot: { up_bytes, up_packets, down_bytes, down_packets } } or null if the table is gone.
// With `slots`, only those sessions' counters are read (a logout must not
// cost a dump of every counter); large sets still use one full dump.
export function read_counters(slots) {
	let partial = slots && length(slots) <= 8;
	let cmd = partial
		? join('; ', map(slots, (s) => `nft -j list counter ${TABLE} cu_${s}; nft -j list counter ${TABLE} cd_${s}`))
		: `nft -j list counters table ${TABLE}`;
	let res = run(cmd);

	if (!partial && res.code != 0)
		return null;

	// One JSON document per nft invocation, one per line.
	let items = [];
	for (let line in split(res.out ?? '', '
')) {
		if (substr(line, 0, 1) != '{')
			continue;

		try { push(items, ...(json(line)?.nftables ?? [])); } catch (e) { }
	}

	let out = {};

	// Names are cu_<slot> / cd_<slot>; plain slicing is much cheaper than a
	// regex when there are thousands of them.
	for (let item in items) {
		let c = item.counter;
		let name = c?.name;

		if (!name || substr(name, 0, 1) != 'c' || substr(name, 2, 1) != '_')
			continue;

		let dir = substr(name, 1, 1), slot = substr(name, 3);
		let e = (out[slot] ??= { up_bytes: 0, up_packets: 0, down_bytes: 0, down_packets: 0 });

		if (dir == 'u') {
			e.up_bytes = c.bytes;
			e.up_packets = c.packets;
		}
		else {
			e.down_bytes = c.bytes;
			e.down_packets = c.packets;
		}
	}

	return out;
};

export function delete_table() {
	return run(`nft delete table ${TABLE}`).code == 0;
};
