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

// state: { ifaces:[dev], port, bypass:[mac], block:[mac], sessions:[{slot, mac}] }
export function ruleset(state) {
	let ifaces = map(state.ifaces, q);
	let sessions = state.sessions ?? [];
	let marks = map(sessions, (s) => slot_mark(s.slot));
	let r = '';

	r += `table ${TABLE}\n`;
	r += `delete table ${TABLE}\n`;
	r += `table ${TABLE} {\n`;

	r += `\tset hs_ifaces {\n\t\ttype ifname\n${elements(ifaces)}\t}\n`;
	r += `\tset auth_mac {\n\t\ttype ether_addr\n${elements(map(sessions, (s) => s.mac))}\t}\n`;
	r += `\tset bypass_mac {\n\t\ttype ether_addr\n${elements(state.bypass ?? [])}\t}\n`;
	r += `\tset block_mac {\n\t\ttype ether_addr\n${elements(state.block ?? [])}\t}\n`;
	r += `\tmap mac2id {\n\t\ttype ether_addr : mark\n${elements(map(sessions, (s) => `${s.mac} : ${slot_mark(s.slot)}`))}\t}\n`;
	r += `\tset active {\n\t\ttype mark\n${elements(marks)}\t}\n`;

	// Walled garden: static entries (interval) and dnsmasq nftset entries (timeout).
	r += `\tset wg4 {\n\t\ttype ipv4_addr\n\t\tflags interval\n${elements(state.wg4 ?? [])}\t}\n`;
	r += `\tset wg6 {\n\t\ttype ipv6_addr\n\t\tflags interval\n${elements(state.wg6 ?? [])}\t}\n`;
	r += `\tset wgd4 {\n\t\ttype ipv4_addr\n\t\tflags timeout\n\t}\n`;
	r += `\tset wgd6 {\n\t\ttype ipv6_addr\n\t\tflags timeout\n\t}\n`;

	for (let s in sessions)
		r += `\tcounter cu_${s.slot} { }\n\tcounter cd_${s.slot} { }\n`;

	r += `\tmap cnt_up {\n\t\ttype mark : counter\n${elements(map(sessions, (s) => `${slot_mark(s.slot)} : "cu_${s.slot}"`))}\t}\n`;
	r += `\tmap cnt_down {\n\t\ttype mark : counter\n${elements(map(sessions, (s) => `${slot_mark(s.slot)} : "cd_${s.slot}"`))}\t}\n`;

	// Tag new connections with the client's slot. A MAC without a session
	// misses the map lookup and keeps ct mark 0.
	r += `\tchain mark_in {\n`;
	r += `\t\ttype filter hook prerouting priority mangle - 10; policy accept;\n`;
	r += `\t\tiifname @hs_ifaces ct state new ct mark set ether saddr map @mac2id\n`;
	r += `\t}\n`;

	// Unauthenticated clients: DNS to the router, HTTP to the portal.
	r += `\tchain dstnat {\n`;
	r += `\t\ttype nat hook prerouting priority dstnat - 5; policy accept;\n`;
	r += `\t\tiifname != @hs_ifaces return\n`;
	r += `\t\tether saddr @auth_mac return\n`;
	r += `\t\tether saddr @bypass_mac return\n`;
	r += `\t\tfib daddr type local return\n`;
	r += `\t\tip daddr @wg4 return\n\t\tip daddr @wgd4 return\n`;
	r += `\t\tip6 daddr @wg6 return\n\t\tip6 daddr @wgd6 return\n`;
	r += `\t\tmeta l4proto { tcp, udp } th dport 53 redirect to :53\n`;
	r += `\t\ttcp dport 80 redirect to :${state.port}\n`;
	r += `\t}\n`;

	r += `\tchain forward {\n`;
	r += `\t\ttype filter hook forward priority filter - 10; policy accept;\n`;
	r += `\t\tiifname @hs_ifaces jump from_client\n`;
	r += `\t\toifname @hs_ifaces jump to_client\n`;
	r += `\t}\n`;

	r += `\tchain from_client {\n`;
	r += `\t\tether saddr @block_mac drop\n`;
	r += `\t\tether saddr @bypass_mac return\n`;
	r += `\t\tct mark and ${MARK_MASK} != @active jump unauth\n`;
	r += `\t\tcounter name ct mark and ${MARK_MASK} map @cnt_up\n`;
	r += `\t}\n`;

	r += `\tchain to_client {\n`;
	r += `\t\tct mark and ${MARK_MASK} != @active return\n`;
	r += `\t\tcounter name ct mark and ${MARK_MASK} map @cnt_down\n`;
	r += `\t}\n`;

	r += `\tchain unauth {\n`;
	r += `\t\tip daddr @wg4 return\n\t\tip daddr @wgd4 return\n`;
	r += `\t\tip6 daddr @wg6 return\n\t\tip6 daddr @wgd6 return\n`;
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
	];
};

export function set_cmds(set, add, del) {
	let cmds = [];

	if (length(del))
		push(cmds, `destroy element ${TABLE} ${set} { ${list(del)} }`);

	if (length(add))
		push(cmds, `add element ${TABLE} ${set} { ${list(add)} }`);

	return cmds;
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
export function read_counters() {
	let res = run(`nft -j list counters table ${TABLE}`);

	if (res.code != 0)
		return null;

	let data;
	try { data = json(res.out); } catch (e) { return null; }

	let out = {};

	for (let item in data?.nftables ?? []) {
		let c = item.counter;
		let m = c ? match(c.name, /^c([ud])_(\d+)$/) : null;

		if (!m)
			continue;

		let e = (out[m[2]] ??= { up_bytes: 0, up_packets: 0, down_bytes: 0, down_packets: 0 });

		if (m[1] == 'u') {
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
