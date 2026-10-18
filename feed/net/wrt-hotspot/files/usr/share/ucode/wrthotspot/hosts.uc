// Host table (MikroTik /ip hotspot host): every MAC seen on a hotspot
// interface, with its current IPv4 and IPv6 addresses, learned from the
// kernel neighbor table over rtnetlink. Authorization never depends on these
// addresses (it keys on MAC), they are for the portal's IP -> MAC lookup,
// display and RADIUS Framed-IP attributes.
'use strict';

import * as rtnl from 'rtnl';
import { normalize_ip, normalize_mac, ip_family, log } from 'wrthotspot.util';

const C = rtnl.const;

// Entries in these states don't prove the host is there.
const DEAD = [ C.NUD_FAILED, C.NUD_INCOMPLETE, C.NUD_NONE ];

export function create(opts) {
	let hosts = {};		// mac -> host
	let ip2mac = {};	// ip -> mac
	let devices = {};	// dev -> server name
	let listener = null;

	function forget_ip(ip) {
		let mac = ip2mac[ip];

		if (!mac)
			return;

		delete ip2mac[ip];

		let h = hosts[mac];
		if (h) {
			delete h.ip4[ip];
			delete h.ip6[ip];
		}
	}

	function handle(msg, deleted) {
		if (!msg || !msg.dst || !devices[msg.dev])
			return;

		let ip = normalize_ip(msg.dst);

		if (deleted || !msg.lladdr || (msg.state in DEAD)) {
			// A failed entry for a known MAC still means "not reachable now".
			forget_ip(ip);
			return;
		}

		let mac = normalize_mac(msg.lladdr);

		// Multicast/broadcast neighbors (33:33:..., ff02::...) are not hosts.
		if (!mac || (hex(substr(mac, 0, 2)) & 1) || substr(ip, 0, 2) == 'ff')
			return;

		let now = time();

		if (ip2mac[ip] && ip2mac[ip] != mac)
			forget_ip(ip);

		let h = hosts[mac];
		if (!h) {
			h = hosts[mac] = {
				mac, dev: msg.dev, server: devices[msg.dev],
				ip4: {}, ip6: {}, first_seen: now, last_seen: now,
			};
			if (opts && opts.on_new)
				opts.on_new(h);
		}

		h.dev = msg.dev;
		h.server = devices[msg.dev];

		if (ip_family(ip) == 6)
			h.ip6[ip] = now;
		else
			h.ip4[ip] = now;

		ip2mac[ip] = mac;

		if (msg.state & (C.NUD_REACHABLE | C.NUD_PERMANENT)) {
			h.last_seen = now;
			if (opts && opts.on_seen)
				opts.on_seen(h);
		}
	}

	function dump() {
		for (let family in [ C.AF_INET, C.AF_INET6 ]) {
			let res = rtnl.request(C.RTM_GETNEIGH, C.NLM_F_DUMP, { family });

			for (let m in (type(res) == 'array') ? res : [])
				handle(m, false);
		}
	}

	let self;

	self = {
		// devices: { dev: server_name }
		set_devices: function(devs) {
			devices = devs;

			for (let mac, h in hosts) {
				if (!devices[h.dev]) {
					for (let ip in [ ...keys(h.ip4), ...keys(h.ip6) ])
						delete ip2mac[ip];

					delete hosts[mac];
				}
			}

			dump();
		},

		start: function() {
			listener = rtnl.listener((ev) => {
				handle(ev.msg, ev.cmd == C.RTM_DELNEIGH);
			}, [ C.RTM_NEWNEIGH, C.RTM_DELNEIGH ], [ C.RTNLGRP_NEIGH ]);

			if (!listener)
				log('error', 'rtnl neighbor listener failed: %s', rtnl.error());

			dump();
		},

		mac_of: function(ip) {
			ip = normalize_ip(ip);

			if (!ip2mac[ip]) {
				// The neighbor entry may be newer than our last event; ask the kernel.
				let res = rtnl.request(C.RTM_GETNEIGH, C.NLM_F_DUMP, { family: (ip_family(ip) == 6) ? C.AF_INET6 : C.AF_INET });

				for (let m in (type(res) == 'array') ? res : [])
					handle(m, false);
			}

			return ip2mac[ip];
		},

		get: function(mac) { return hosts[mac]; },

		// Make sure a MAC we know about from elsewhere (e.g. a restored session) exists.
		touch: function(mac, dev) {
			let now = time();
			let h = (hosts[mac] ??= { mac, dev, server: devices[dev], ip4: {}, ip6: {}, first_seen: now, last_seen: now });
			h.last_seen = now;
			return h;
		},

		list: function() {
			return map(sort(keys(hosts)), (mac) => self.view(hosts[mac]));
		},

		view: function(h) {
			return {
				mac: h.mac, dev: h.dev, server: h.server,
				ipv4: sort(keys(h.ip4)), ipv6: sort(keys(h.ip6)),
				first_seen: h.first_seen, last_seen: h.last_seen,
			};
		},

		// Drop hosts not seen for `max_idle` seconds (per server) unless `keep(mac)`.
		prune: function(max_idle_of, keep) {
			let now = time();

			for (let mac, h in hosts) {
				let max_idle = max_idle_of(h.server);

				if (max_idle > 0 && now - h.last_seen > max_idle && !keep(mac)) {
					for (let ip in [ ...keys(h.ip4), ...keys(h.ip6) ])
						delete ip2mac[ip];

					delete hosts[mac];
				}
			}
		},
	};

	return self;
};
