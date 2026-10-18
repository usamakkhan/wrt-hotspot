// ubus object `wrthotspot`: the single control interface used by the
// captive portal, the CLI, the LuCI rpcd plugin and the operator panel.
'use strict';

import { public_view } from 'wrthotspot.users';
import { VERSION, CAUSE } from 'wrthotspot.core';

const USER_ARGS = {
	name: '', password: '', profile: '', server: '', mac: '',
	limit_uptime: '', limit_bytes_in: '', limit_bytes_out: '', limit_bytes_total: '',
	disabled: false, comment: '', email: '',
};

export function publish(conn, core) {
	function err(msg) {
		return { ok: false, error: msg };
	}

	return conn.publish('wrthotspot', {
		status: {
			call: function() {
				return {
					version: VERSION,
					devices: core.devices(),
					sessions: length(core.sessions()),
					hosts: length(core.hosts()),
					users: core.users().count(),
				};
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
				return core.login(req.args);
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
	});
};
