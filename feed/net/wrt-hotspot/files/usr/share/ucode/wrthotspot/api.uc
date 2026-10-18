// ubus object `wrthotspot`: the single control interface used by the
// captive portal, the CLI, the LuCI rpcd plugin and the operator panel.
'use strict';

import * as uloop from 'uloop';
import { public_view } from 'wrthotspot.users';
import { VERSION, CAUSE } from 'wrthotspot.core';
import { run_checks } from 'wrthotspot.diag';
import * as vouchers from 'wrthotspot.vouchers';
import * as operators from 'wrthotspot.operators';
import { run, shell_quote } from 'wrthotspot.util';

const USER_ARGS = {
	name: '', password: '', profile: '', server: '', mac: '',
	limit_uptime: '', limit_bytes_in: '', limit_bytes_out: '', limit_bytes_total: '',
	disabled: false, comment: '', email: '',
	validity: '', expires: '', price: '', batch: '',
};

// Lists are paged: a ubus message is limited to 1 MiB, which a few thousand
// sessions or vouchers would exceed. limit 0 = the default page size.
const PAGE_ARGS = { offset: 0, limit: 0, search: '' };
const PAGE_MAX = 1000;

function page(list, a, text) {
	let q = lc(a.search ?? '');

	if (q != '')
		list = filter(list, (x) => index(lc(text(x)), q) >= 0);

	let offset = max(0, a.offset ?? 0);
	let limit = (a.limit > 0) ? min(a.limit, PAGE_MAX) : PAGE_MAX;

	return { items: slice(list, offset, offset + limit), total: length(list), offset };
}

export function publish(conn, core) {
	function err(msg) {
		return { ok: false, error: msg };
	}

	// Login name behind an rpcd session (LuCI / operator panel), for audit.
	function caller(req) {
		let sid = req.args.ubus_rpc_session;

		if (!sid)
			return 'root';

		return conn.call('session', 'get', { ubus_rpc_session: sid })?.values?.username ?? '';
	}

	let methods = {
		status: {
			call: function() {
				return {
					version: VERSION,
					devices: core.devices(),
					sessions: core.session_count(),
					hosts: core.host_count(),
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
			args: PAGE_ARGS,
			call: function(req) {
				let p = page(core.sessions(), req.args, (s) => `${s.user} ${s.mac} ${join(' ', s.ipv4)} ${s.id}`);
				return { sessions: p.items, total: p.total, offset: p.offset };
			},
		},

		hosts: {
			args: PAGE_ARGS,
			call: function(req) {
				let p = page(core.hosts(), req.args, (h) => `${h.mac} ${join(' ', h.ipv4)} ${join(' ', h.ipv6)}`);
				return { hosts: p.items, total: p.total, offset: p.offset };
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

		// Who am I (operator panel): login name and what the session may do.
		whoami: {
			call: function(req) {
				let sid = req.args.ubus_rpc_session;
				let admin = sid ? !!conn.call('session', 'access', { ubus_rpc_session: sid, scope: 'ubus', object: 'wrthotspot', function: 'operator_set' })?.access : true;

				return { username: caller(req), admin };
			},
		},

		profiles: {
			call: function() {
				let cfg = core.config();
				let out = {};

				for (let n, p in cfg.user_profiles)
					out[n] = { rate_limit: p.rate_limit, session_timeout: p.session_timeout, shared_users: p.shared_users, limitations: p.limitations };

				return { user_profiles: out, servers: keys(cfg.servers) };
			},
		},

		voucher_create: {
			args: {
				profile: '', count: 0, prefix: '', length: 0, charset: '', password: '', password_length: 0,
				validity: '', limit_uptime: '', limit_bytes_total: '', limit_bytes_in: '', limit_bytes_out: '',
				price: '', comment: '', server: '',
			},
			call: function(req) {
				let res = vouchers.create(core.users(), req.args, caller(req), core.config().user_profiles);
				return res[0] ? { ok: true, ...res[0] } : err(res[1]);
			},
		},

		voucher_batches: {
			call: function() {
				return { batches: vouchers.batches(core.users()) };
			},
		},

		voucher_list: {
			args: { batch: '' },
			call: function(req) {
				if (!req.args.batch)
					return err('batch is required');

				return { vouchers: vouchers.list(core.users(), req.args.batch) };
			},
		},

		voucher_revoke: {
			args: { batch: '', all: false },
			call: function(req) {
				let names = vouchers.revoke(core.users(), req.args.batch, req.args.all);

				for (let n in names)
					core.logout_where({ user: n }, CAUSE.USER_REMOVED);

				return { ok: true, count: length(names) };
			},
		},

		history: {
			args: { from: 0, to: 0, search: '', limit: 0 },	// int32 epochs: rpcd sends small JSON numbers as int32
			call: function(req) {
				return { history: core.records().query(req.args) };
			},
		},

		report: {
			args: { from: 0, to: 0, group: '' },
			call: function(req) {
				let a = req.args;
				let to = a.to || time();
				let from = a.from || (to - 7 * 86400);
				let r = core.records().report(from, to, a.group || 'day');

				r.online = core.session_count();
				return r;
			},
		},

		operator_list: {
			call: function() {
				return { operators: operators.list() };
			},
		},

		operator_set: {
			args: { username: '', password: '', role: '', comment: '' },
			call: function(req) {
				let a = req.args;
				let e = operators.set(a.username, (a.password === '' || a.password == null) ? null : a.password, a.role || 'operator', a.comment);
				return e ? err(e) : { ok: true };
			},
		},

		operator_remove: {
			args: { username: '' },
			call: function(req) {
				if (req.args.username == caller(req))
					return err('you cannot remove your own account');

				let e = operators.remove(req.args.username);
				return e ? err(e) : { ok: true };
			},
		},

		user_list: {
			args: PAGE_ARGS,
			call: function(req) {
				let p = page(core.users().list(), req.args, (u) => `${u.name} ${u.comment} ${u.batch} ${u.email}`);
				return { users: map(p.items, public_view), total: p.total, offset: p.offset };
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
