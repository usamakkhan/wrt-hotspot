// Generate a ruleset that uses every feature and print it, for `nft -c -f -`.
'use strict';
import * as nft from 'wrthotspot.nft';

let devices = { 'br-hs': 'hs1' };

print(nft.ruleset({
	ifaces: keys(devices), devices, port: 8002,
	sessions: [ { slot: 1, mac: '02:00:00:00:00:10' }, { slot: 2, mac: '02:00:00:00:00:11' } ],
	bindings: [
		{ type: 'bypassed', server: 'all', mac: '02:00:00:00:00:01', address: null },
		{ type: 'bypassed', server: 'all', mac: null, address: { family: 4, cidr: '10.0.0.0/24' } },
		{ type: 'blocked', server: 'all', mac: null, address: { family: 6, cidr: 'fd00::/64' } },
		{ type: 'bypassed', server: 'all', mac: '02:00:00:00:00:02', address: { family: 4, cidr: '10.0.0.2' } },
		{ type: 'blocked', server: 'all', mac: '02:00:00:00:00:05', address: { family: 6, cidr: 'fd00::5' } },
		{ type: 'blocked', server: 'hs1', mac: '02:00:00:00:00:03', address: null },
	],
	walled_garden: [
		{ idx: 1, action: 'allow', server: 'all', host: 'example.com', prefixes: [], protocol: null, dst_port: null },
		{ idx: 2, action: 'allow', server: 'hs1', host: null, prefixes: [ { family: 4, cidr: '203.0.113.0/24' }, { family: 6, cidr: '2001:db8::/32' } ], protocol: 'tcp', dst_port: '443' },
		{ idx: 3, action: 'deny', server: 'all', host: null, prefixes: [ { family: 4, cidr: '203.0.113.9' } ], protocol: null, dst_port: null },
		{ idx: 4, action: 'allow', server: 'all', host: null, prefixes: [], protocol: 'udp', dst_port: '3478-3479' },
		{ idx: 5, action: 'allow', server: 'all', host: 'x.org', prefixes: [], protocol: 'tcp', dst_port: '443' },
	],
	wg_ttl: 3600,
}));
