// ubus object `wrthotspot`: the single control interface used by the
// captive portal, the CLI, the LuCI rpcd plugin and the operator panel.
'use strict';

import * as uloop from 'uloop';
import { public_view } from 'wrthotspot.users';
import { VERSION, CAUSE } from 'wrthotspot.core';
import { run_checks } from 'wrthotspot.diag';
import * as vouchers from 'wrthotspot.vouchers';
import * as operators from 'wrthotspot.operators';
import * as pages from 'wrthotspot.pages';
import { run, shell_quote } from 'wrthotspot.util';

const USER_ARGS = {
	name: '', password: '', profile: '', server: '', mac: '',
	limit_uptime: '', limit_bytes_in: '', limit_bytes_out: '', limit_bytes_total: '',
	disabled: false, comment: '', email: '',
	validity: '', expires: '', price: '', batch: '',
	force: false,	// admins: create beyond the capacity limit
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

	// rpcd keeps the ACLs a session got at login: after a role or password
	// change (or removal) the account's open sessions must end. rpcd answers
	// "session list" with one message per session, so read the CLI output.
	function end_sessions(username, keep_sid) {
		let out = run('ubus call session list 2>/dev/null').out ?? '';

		for (let chunk in split(out, /\n\}\n/)) {
			let sid = match(chunk, /"ubus_rpc_session": "([0-9a-f]{32})"/);
			let who = match(chunk, /"username": "([^"]*)"/);

			if (sid && who && who[1] == username && sid[1] != keep_sid)
				conn.call('session', 'destroy', { ubus_rpc_session: sid[1] });
		}
	}

	// Admins (LuCI root, panel admins, local ubus callers) may manage operators.
	function is_admin(req) {
		let sid = req.args.ubus_rpc_session;

		return sid ? !!conn.call('session', 'access', { ubus_rpc_session: sid, scope: 'ubus', object: 'wrthotspot', function: 'operator_set' })?.access : true;
	}

	// What portal.uc needs of the configuration, so that it does not parse
	// UCI on every request: the globals it uses and the client's server profile.
	function portal_settings(server) {
		let cfg = core.config();
		let g = cfg.global;
		let sp = cfg.server_profiles[cfg.servers[server]?.profile] ?? cfg.server_profiles.default;

		return {
			portal_port: g.portal_port, https_port: g.https_port, nas_identifier: g.nas_identifier,
			ssl_certificate: g.ssl_certificate, ssl_key: g.ssl_key,
			profile: { dns_name: sp?.dns_name, html_directory: sp?.html_directory, login_by: sp?.login_by ?? [] },
		};
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
					return { found: false, portal: portal_settings(null) };

				return { found: true, ...c, ...core.chap_for(c.mac), portal: portal_settings(c.server) };
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
				// tz_offset: the router's UTC offset (s). Reports group by the
				// router's days, so the panel must count days the same way.
				let now = time();
				return { username: caller(req), admin: is_admin(req), tz_offset: timegm(localtime(now)) - now };
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
				price: '', comment: '', server: '', force: false,
			},
			call: function(req) {
				let who = caller(req);
				let c = core.check_users(int(req.args.count ?? 0), req.args.force && is_admin(req), who);

				if (!c[0])
					return { ...err(c[1]), capacity: core.capacity() };

				let res = vouchers.create(core.users(), req.args, who, core.config().user_profiles);
				return res[0] ? { ok: true, ...res[0], warning: c[1] } : err(res[1]);
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
				// Ordinary users have batch "": an empty batch would select them all.
				if (!req.args.batch)
					return err('batch is required');

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

				if (!e)
					end_sessions(a.username, req.args.ubus_rpc_session);

				return e ? err(e) : { ok: true };
			},
		},

		operator_remove: {
			args: { username: '' },
			call: function(req) {
				if (req.args.username == caller(req))
					return err('you cannot remove your own account');

				let e = operators.remove(req.args.username);

				if (!e)
					end_sessions(req.args.username, req.args.ubus_rpc_session);

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
				let force = a.force;
				delete a.name;
				delete a.force;
				delete a.ubus_rpc_session;

				let c = [ true, null ];
				if (!core.users().get(name))
					c = core.check_users(1, force && is_admin(req), caller(req));

				if (!c[0])
					return { ...err(c[1]), capacity: core.capacity() };

				let res = core.users().set(name, a);
				return res[0] ? { ok: true, user: public_view(res[0]), warning: c[1] } : err(res[1]);
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

		// Login page sets (LuCI "Login Pages"). Uploads: begin, put... , commit.
		pages_list: {
			call: function() {
				return {
					pages: pages.list(core.config()),
					limits: { file: pages.MAX_FILE, total: pages.MAX_TOTAL, files: pages.MAX_FILES, chunk: pages.CHUNK },
					extensions: pages.EXTENSIONS,
				};
			},
		},

		pages_files: {
			args: { name: '' },
			call: function(req) {
				let r = pages.files(req.args.name);
				return r[0] ? { ok: true, files: r[0] } : err(r[1]);
			},
		},

		pages_read: {
			args: { name: '', path: '', offset: 0 },
			call: function(req) {
				let r = pages.read(req.args.name, req.args.path, req.args.offset);
				return r[0] ? { ok: true, ...r[0] } : err(r[1]);
			},
		},

		pages_begin: {
			args: { name: '' },
			call: function(req) {
				let r = pages.begin(req.args.name);
				return r[0] ? { ok: true, token: r[0] } : err(r[1]);
			},
		},

		pages_put: {
			args: { name: '', token: '', path: '', data: '', offset: 0 },
			call: function(req) {
				let a = req.args;
				let e = pages.put(a.name, a.token, a.path, a.data, a.offset);
				return e ? err(e) : { ok: true };
			},
		},

		pages_commit: {
			args: { name: '', token: '' },
			call: function(req) {
				let r = pages.commit(req.args.name, req.args.token);
				return r[0] ? { ok: true, ...r[0] } : err(r[1]);
			},
		},

		pages_remove: {
			args: { name: '' },
			call: function(req) {
				let e = pages.remove(req.args.name, core.config());
				return e ? err(e) : { ok: true };
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
