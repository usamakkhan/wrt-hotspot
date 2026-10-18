// ubus object `wrthotspot`: the single control interface used by the
// captive portal, the CLI, the LuCI rpcd plugin and the operator panel.
'use strict';

import * as uloop from 'uloop';
import { public_view } from 'wrthotspot.users';
import { VERSION, CAUSE } from 'wrthotspot.core';
import { run_checks } from 'wrthotspot.diag';
import { run, shell_quote } from 'wrthotspot.util';

const USER_ARGS = {
	name: '', password: '', profile: '', server: '', mac: '',
	limit_uptime: '', limit_bytes_in: '', limit_bytes_out: '', limit_bytes_total: '',
	disabled: false, comment: '', email: '',
};

export function publish(conn, core) {
	function err(msg) {
		return { ok: false, error: msg };
	}

	let methods = {
		status: {
			call: function() {
				return {
					version: VERSION,
					devices: core.devices(),
					sessions: length(core.sessions()),
					hosts: length(core.hosts()),
					users: core.users().count(),
					...core.runtime(),
				};
			},
		},

		// Health checks for the diagnostics page.
		check: {
			call: function() {
				return { checks: run_checks(core.config(), { running: true, devices: core.devices(), ...core.runtime() }) };
			},
		},

		// Same as `wrthotspot setup <network>`, then apply it in the background
		// (the reload of hotspotd itself must not run inside this call).
		setup: {
			args: { network: '' },
			call: function(req) {
				let net = req.args.network;

				if (!match(net ?? '', /^[A-Za-z0-9_]+$/))
					return err('invalid network name');

				let r = run(`/usr/sbin/wrthotspot setup ${shell_quote(net)}`);

				if (r.code != 0)
					return err(trim(r.out));

				uloop.process('/bin/sh', [ '-c',
					'/etc/init.d/network reload; /etc/init.d/firewall reload; /etc/init.d/dnsmasq restart; ' +
					'/etc/init.d/odhcpd restart; /etc/init.d/wrthotspot reload' ], {}, () => {});

				return { ok: true, output: trim(r.out) };
			},
		},

		// Portal: who is this client, and is it logged in?
		client: {
			args: { ip: '', mac: '' },
			call: function(req) {
				let c = core.client(req.args.ip, req.args.mac);

				if (!c)
					return { found: false };

				return { found: true, ...c, ...core.chap_for(c.mac) };
			},
		},

		login: {
			args: { ip: '', mac: '', method: '', username: '', password: '', chap_response: '', cookie: '' },
			call: function(req) {
				let res = core.login(req.args, (r) => req.reply(r));

				// RADIUS logins answer later: keep the ubus request open.
				return (res != null) ? res : req.defer();
			},
		},

		logout: {
			args: { ip: '', mac: '', id: '', user: '', cause: '' },
			call: function(req) {
				let a = req.args;

				if (!a.ip && !a.mac && !a.id && !a.user)
					return err('one of ip, mac, id or user is required');

				let cause = (a.cause in values(CAUSE)) ? a.cause : (a.ip ? CAUSE.USER : CAUSE.ADMIN);
				return { ok: true, count: core.logout_where(a, cause) };
			},
		},

		sessions: {
			call: function() {
				return { sessions: core.sessions() };
			},
		},

		hosts: {
			call: function() {
				return { hosts: core.hosts() };
			},
		},

		cookies: {
			call: function() {
				return core.cookies();
			},
		},

		cookie_remove: {
			args: { mac: '', user: '' },
			call: function(req) {
				if (!req.args.mac && !req.args.user)
					return err('mac or user is required');

				return { ok: true, count: core.cookie_remove(req.args) };
			},
		},

		user_list: {
			call: function() {
				return { users: map(core.users().list(), public_view) };
			},
		},

		user_get: {
			args: { name: '' },
			call: function(req) {
				let u = core.users().get(req.args.name);
				return u ? { ok: true, user: public_view(u) } : err('no such user');
			},
		},

		user_set: {
			args: USER_ARGS,
			call: function(req) {
				let a = { ...req.args };
				let name = a.name;
				delete a.name;

				let res = core.users().set(name, a);
				return res[0] ? { ok: true, user: public_view(res[0]) } : err(res[1]);
			},
		},

		user_remove: {
			args: { name: '' },
			call: function(req) {
				let name = req.args.name;

				if (!core.users().remove(name))
					return err('no such user');

				core.logout_where({ user: name }, CAUSE.USER_REMOVED);
				return { ok: true };
			},
		},

		user_reset_counters: {
			args: { name: '' },
			call: function(req) {
				return core.users().reset_counters(req.args.name) ? { ok: true } : err('no such user');
			},
		},

		reload: {
			call: function() {
				let e = core.reload();
				return e ? err(e) : { ok: true };
			},
		},

		// Log everybody out and remove the dataplane (the next reload rebuilds it).
		flush: {
			call: function() {
				core.flush();
				return { ok: true };
			},
		},
	};

	// Calls forwarded by rpcd (LuCI, the operator panel) carry the caller's
	// ubus_rpc_session; ucode rejects undeclared arguments, so accept it.
	for (let name, m in methods) {
		m.args ??= {};
		m.args.ubus_rpc_session = '';
	}

	return conn.publish('wrthotspot', methods);
};
