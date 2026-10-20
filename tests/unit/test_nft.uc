'use strict';
import { suite, eq, ok, done } from 'assert';
import * as nft from 'wrthotspot.nft';

suite('nft');

eq(nft.slot_mark(1), 65536, 'slot mark shift');
eq(nft.slot_mark(65535), 4294901760, 'max slot');

let r = nft.ruleset({ ifaces: [ 'br-hs' ], port: 8002, sessions: [ { slot: 3, mac: 'aa:bb:cc:dd:ee:ff' } ] });

ok(index(r, 'delete table inet wrthotspot') > 0, 'atomic replace');
ok(index(r, 'elements = { "br-hs" }') > 0, 'interfaces');
ok(index(r, 'aa:bb:cc:dd:ee:ff : 196608') > 0, 'mac2id element');
ok(index(r, 'counter cu_3 { }') > 0, 'upload counter');
ok(index(r, '196608 : "cd_3"') > 0, 'download counter map');
ok(index(r, 'redirect to :8002') > 0, 'portal port');
ok(index(r, 'elements = {  }') < 0, 'no empty element lists');

let add = nft.session_add_cmds(3, 'aa:bb:cc:dd:ee:ff');
eq(length(add), 7, 'add cmds');
ok(index(join('\n', nft.session_del_cmds(3, 'aa:bb:cc:dd:ee:ff')), 'destroy counter inet wrthotspot cd_3') >= 0, 'del uses destroy');

// Bindings and walled garden.
let devices = { 'br-hs': 'hs1', 'br-guest': 'guest' };
r = nft.ruleset({
	ifaces: keys(devices), devices, port: 8002, sessions: [],
	bindings: [
		{ type: 'bypassed', server: 'all', mac: '02:00:00:00:00:01', address: null },
		{ type: 'blocked', server: 'all', mac: null, address: { family: 6, cidr: 'fd00::/64' } },
		{ type: 'bypassed', server: 'all', mac: '02:00:00:00:00:02', address: { family: 4, cidr: '10.0.0.2' } },
		{ type: 'blocked', server: 'guest', mac: '02:00:00:00:00:03', address: null },
		{ type: 'regular', server: 'all', mac: '02:00:00:00:00:04', address: null },
	],
	walled_garden: [
		{ idx: 1, action: 'allow', server: 'all', host: 'example.com', prefixes: [], protocol: null, dst_port: null },
		{ idx: 2, action: 'allow', server: 'hs1', host: null, prefixes: [ { family: 4, cidr: '203.0.113.0/24' }, { family: 6, cidr: '2001:db8::/32' } ], protocol: 'tcp', dst_port: '443' },
		{ idx: 3, action: 'deny', server: 'all', host: null, prefixes: [ { family: 4, cidr: '203.0.113.9' } ], protocol: null, dst_port: null },
		{ idx: 4, action: 'allow', server: 'nosuch', host: 'x.org', prefixes: [], protocol: null, dst_port: null },
	],
	wg_ttl: 600,
});

ok(index(r, 'set bypass_mac {\n\t\ttype ether_addr\n\t\telements = { 02:00:00:00:00:01 }') > 0, 'bypass mac in set');
ok(index(r, 'set block6 {\n\t\ttype ipv6_addr\n\t\tflags interval\n\t\tauto-merge\n\t\telements = { fd00::/64 }') > 0, 'block prefix in set (auto-merge: overlaps must not fail the ruleset)');
ok(index(r, 'elements = { 02:00:00:00:00:02 . 10.0.0.2 }') > 0, 'mac+ip pair');
ok(index(r, 'iifname { "br-guest" } ether saddr 02:00:00:00:00:03 drop') > 0, 'server-scoped block rule');
ok(index(r, '02:00:00:00:00:04') < 0, 'regular binding has no rule');
ok(index(r, 'set wgh1_4 {\n\t\ttype ipv4_addr\n\t\tflags timeout\n\t\ttimeout 600s') > 0, 'host set with ttl');
ok(index(r, 'ip6 daddr @wgh1_6 accept') > 0, 'host allow v6');
ok(index(r, 'iifname { "br-hs" } ip daddr { 203.0.113.0/24 } meta l4proto tcp th dport 443 accept') > 0, 'prefix+port allow');
ok(index(r, 'iifname { "br-hs" } ip6 daddr { 2001:db8::/32 } meta l4proto tcp th dport 443 accept') > 0, 'v6 prefix+port allow');
ok(index(r, 'ip daddr { 203.0.113.9 } return') < index(r, 'ip daddr @wgh1_4 accept'), 'deny before allow');
ok(index(r, 'wgh4_4 accept') < 0, 'server without device matches nothing');

eq(nft.wg_refresh_cmds(1, 4, [ '1.2.3.4' ], 60), [
	'destroy element inet wrthotspot wgh1_4 { 1.2.3.4 }',
	'add element inet wrthotspot wgh1_4 { 1.2.3.4 timeout 60s }',
], 'refresh cmds');
eq(nft.wg_refresh_cmds(1, 6, [], 60), [], 'no-op refresh');

done();
