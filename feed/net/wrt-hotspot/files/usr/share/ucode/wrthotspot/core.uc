// hotspotd core: sessions (MikroTik /ip hotspot active), login methods,
// cookies, limits, accounting and crash/restart recovery.
'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';
import { md5 } from 'digest';
import * as nft from 'wrthotspot.nft';
import * as dns from 'wrthotspot.dns';
import * as radius from 'wrthotspot.radius';
import * as shaper from 'wrthotspot.shaper';
import * as sched from 'wrthotspot.limits';
import * as users_db from 'wrthotspot.users';
import * as hosts_mod from 'wrthotspot.hosts';
import * as records_mod from 'wrthotspot.records';
import { load as load_config } from 'wrthotspot.config';
import {
	log, set_log_level, normalize_mac, normalize_ip, random_bytes, random_hex, run,
	read_json, write_atomic, mkdir_p, fmt_duration, fmt_bytes
} from 'wrthotspot.util';

export const VERSION = '0.2.0';

// MikroTik / RADIUS terminate causes.
export const CAUSE = {
	USER: 'user-request',
	ADMIN: 'admin-reset',
	SESSION_TIMEOUT: 'session-timeout',
	IDLE_TIMEOUT: 'idle-timeout',
	KEEPALIVE_TIMEOUT: 'keepalive-timeout',
	TRAFFIC_LIMIT: 'traffic-limit',
	UPTIME_LIMIT: 'uptime-limit',
	NEW_LOGIN: 'new-login',
	USER_REMOVED: 'user-removed',
	NAS_REBOOT: 'nas-reboot',
};

// Cookies survive only these causes: the device left (idle/keepalive) or
// the router restarted. Everything else (explicit logout, admin reset,
// limits, session-timeout) removes them, as on MikroTik.
const COOKIE_KEEP = [ CAUSE.IDLE_TIMEOUT, CAUSE.KEEPALIVE_TIMEOUT, CAUSE.NEW_LOGIN, CAUSE.NAS_REBOOT ];

const CHAP_TTL = 300;

function octal_escape(bin) {
	let out = '';

	for (let i = 0; i < length(bin); i++)
		out += sprintf('\\%03o', ord(bin, i));

	return out;
}

export function create(opts) {
	let confdir = opts?.confdir;
	let cfg;
	let conn = opts?.ubus;		// may be null in tests
	let hooks_enabled = !opts?.no_hooks;

	let sessions = {};		// slot -> session
	let by_mac = {};		// mac -> slot
	let next_slot = 1;
	let devices = {};		// dev -> server name
	let chap = {};			// mac -> { id, challenge, expires }
	let trials = {};		// mac -> { used, window_start }
	let cookies = {};		// token -> { user, mac, server, expires }
	let mac_cookies = {};		// mac -> { user, server, expires }
	let cookies_dirty = false;
	let users;
	let hosts;
	let records;			// session history + voucher sales
	let need_rebuild = true;
	let dev_info = {};		// dev -> { ip4 } (NAS-IP-Address)
	let rad = radius.client();
	let coa = null;
	let setup_shaper, reapply_rates;	// defined below, used by self.reload
	let shp = null;			// shaper backend: tc object, 'nft' or null (off)
	let polls = 0;
	let try_mac_cookie;		// defined below, used by self.client
	let auto_login;
	let mac_tried = {};		// mac -> last automatic MAC login attempt

	let self = {};

	/* ---------- helpers ---------- */

	function server_profile_of(server_name) {
		let srv = cfg.servers[server_name];
		return cfg.server_profiles[srv?.profile] ?? cfg.server_profiles.default;
	}

	function user_profile(name) {
		return cfg.user_profiles[name] ?? cfg.user_profiles.default;
	}

	function alloc_slot() {
		for (let n = 0; n < nft.MAX_SLOT; n++) {
			let s = next_slot;
			next_slot = (next_slot % nft.MAX_SLOT) + 1;

			if (!sessions[s])
				return s;
		}

		return null;
	}

	function state_path(name) {
		return `${cfg.global.state_dir}/${name}`;
	}

	function checkpoint() {
		write_atomic(state_path('sessions.json'), sprintf('%J', {
			version: 1, saved: time(), next_slot, sessions: values(sessions), trials,
		}));
	}

	function totals(s) {
		return {
			bytes_in: s.base.up_bytes + s.k.up_bytes,
			bytes_out: s.base.down_bytes + s.k.down_bytes,
			packets_in: s.base.up_packets + s.k.up_packets,
			packets_out: s.base.down_packets + s.k.down_packets,
		};
	}

	function exec(cmds) {
		if (!length(cmds))
			return null;

		if (need_rebuild)
			return self.rebuild();

		let err = nft.apply(join('\n', cmds) + '\n', cfg.global.state_dir);

		// Never leave the kernel out of sync: fall back to a full rebuild.
		if (err)
			return self.rebuild();

		return null;
	}

	function run_hook(script, env) {
		if (!hooks_enabled || !script)
			return;

		uloop.process('/bin/sh', [ '-c', script ], env, (code) => {
			if (code != 0)
				log('warn', 'Hook exited with %d', code);
		});
	}

	function event(name, data) {
		if (conn)
			conn.event(`wrthotspot.${name}`, data);
	}

	function hook_env(s, cause) {
		let t = totals(s);
		let h = hosts.get(s.mac);

		return {
			PATH: '/usr/sbin:/usr/bin:/sbin:/bin',
			HS_USER: s.user, HS_MAC: s.mac, HS_SERVER: s.server, HS_INTERFACE: s.dev,
			HS_ADDRESS: h ? (sort(keys(h.ip4))[0] ?? '') : '',
			HS_ADDRESS6: h ? join(' ', sort(keys(h.ip6))) : '',
			HS_SESSION_ID: s.id, HS_LOGIN_BY: s.login_by,
			HS_UPTIME: `${time() - s.started}`,
			HS_BYTES_IN: `${t.bytes_in}`, HS_BYTES_OUT: `${t.bytes_out}`,
			HS_CAUSE: cause ?? '',
		};
	}

	/* ---------- cookies ---------- */

	function cookies_path() {
		return `${cfg.global.db_dir}/cookies.json`;
	}

	function load_cookies() {
		let c = read_json(cookies_path());
		cookies = c?.cookies ?? {};
		mac_cookies = c?.mac_cookies ?? {};
	}

	function save_cookies(force) {
		if (!cookies_dirty && !force)
			return;

		let now = time();

		for (let t, c in cookies)
			if (c.expires < now)
				delete cookies[t];

		for (let m, c in mac_cookies)
			if (c.expires < now)
				delete mac_cookies[m];

		write_atomic(cookies_path(), sprintf('%J', { version: 1, cookies, mac_cookies }), 0o600);
		cookies_dirty = false;
	}

	function drop_cookies(mac) {
		for (let t, c in cookies)
			if (c.mac == mac)
				delete cookies[t];

		delete mac_cookies[mac];
		cookies_dirty = true;
	}

	// After a credential login: remember the device, as configured. For
	// RADIUS users the authorization (`radius_auth`) is kept with the cookie
	// and replayed on cookie logins, so no password needs to be stored.
	function issue_cookies(mac, server, username, profile, radius_auth) {
		let sp = server_profile_of(server);
		let up = user_profile(profile);
		let token = null;

		if ('cookie' in sp.login_by) {
			token = random_hex(16);
			cookies[token] = { user: username, mac, server, radius: radius_auth, expires: time() + sp.http_cookie_lifetime };
			cookies_dirty = true;
		}

		if ('mac-cookie' in sp.login_by && up.add_mac_cookie) {
			mac_cookies[mac] = { user: username, server, radius: radius_auth, expires: time() + up.mac_cookie_timeout };
			cookies_dirty = true;
		}

		return token;
	}

	/* ---------- configuration & devices ---------- */

	function resolve_devices() {
		let devs = {};

		dev_info = {};

		for (let name, srv in cfg.servers) {
			if (!srv.enabled)
				continue;

			let dev = srv.device;
			let st = null;

			if (srv.interface && conn) {
				st = conn.call(`network.interface.${srv.interface}`, 'status');
				dev ??= st?.l3_device ?? st?.device;
			}

			if (!dev) {
				log('warn', 'Server %s: interface %s has no device yet', name, srv.interface);
				continue;
			}

			devs[dev] = name;
			dev_info[dev] = { ip4: st?.['ipv4-address']?.[0]?.address };
		}

		return devs;
	}

	/* ---------- RADIUS: servers, CoA listener ---------- */

	function setup_radius() {
		rad.set_servers(cfg.radius);

		let want = (length(cfg.radius) && cfg.global.coa_port > 0) ? cfg.global.coa_port : 0;

		if (coa && coa.port != want) {
			coa.close();
			coa = null;
		}

		if (want && !coa && !opts?.no_coa) {
			let h = radius.coa_server(want, () => cfg.radius, (pkt, srv) => self.coa(pkt, srv));

			if (h) {
				coa = { ...h, port: want };
				log('info', 'Listening for RADIUS CoA/Disconnect on port %d', want);
			}
		}

		let worst = 0;
		for (let r in cfg.radius)
			worst += r.timeout * (r.retries + 1);

		if (worst > 9000)
			log('warn', 'RADIUS timeout x retries over all servers is %d ms; portal logins may time out', worst);
	}

	function apply_dns() {
		if (opts?.no_dns)
			return;

		if (!dns.dnsmasq_has_nftset() && length(filter(cfg.walled_garden, (e) => e.host)))
			log('warn', 'dnsmasq lacks nftset support (install dnsmasq-full): walled-garden subdomains are not covered, only the listed hosts');

		dns.apply_dnsmasq(cfg, devices);
		dns.apply_odhcpd(cfg);
	}

	self.reload = function() {
		cfg = load_config(confdir);
		set_log_level(cfg.global.log_level);
		mkdir_p(cfg.global.state_dir);

		devices = resolve_devices();

		if (hosts)
			hosts.set_devices(devices);

		setup_radius();
		setup_shaper();

		// Bindings and walled garden may have changed: always rebuild.
		let err = self.rebuild();
		apply_dns();
		reapply_rates();
		return err;
	};

	self.devices = () => devices;

	// Runtime facts for status and diagnostics.
	self.runtime = () => ({
		shaper: (shp == null) ? 'off' : (shp == 'nft') ? 'nft' : 'tc',
		radius_backlog: rad.backlog(),
		coa_listening: !!coa,
	});
	self.config = () => cfg;

	/* ---------- kernel state ---------- */

	// Recreate the whole table from daemon state in one atomic transaction.
	// Kernel counters restart from zero, so fold them into each session's base.
	self.rebuild = function() {
		let kc = nft.read_counters();

		for (let slot, s in sessions) {
			let k = kc?.[slot] ?? s.k;

			for (let f in [ 'up_bytes', 'up_packets', 'down_bytes', 'down_packets' ])
				s.base[f] += k[f] ?? 0;

			s.k = { up_bytes: 0, up_packets: 0, down_bytes: 0, down_packets: 0 };
		}

		let text = nft.ruleset({
			ifaces: keys(devices),
			devices,
			port: cfg.global.portal_port,
			sessions: map(values(sessions), (s) => ({ slot: s.slot, mac: s.mac, lim: s.nft_lim })),
			bindings: cfg.ip_bindings,
			walled_garden: cfg.walled_garden,
			wg_ttl: cfg.global.walled_garden_ttl,
		});

		let err = nft.apply(text, cfg.global.state_dir);

		if (err) {
			need_rebuild = true;
			return err;
		}

		need_rebuild = false;
		checkpoint();
		log('info', 'Dataplane built: %d device(s), %d session(s), %d binding(s), %d walled-garden entr%s',
			length(keys(devices)), length(keys(sessions)), length(cfg.ip_bindings), length(cfg.walled_garden),
			(length(cfg.walled_garden) == 1) ? 'y' : 'ies');

		// The rebuild emptied the walled-garden host sets: refill them.
		self.resolve();
		return null;
	};

	self.resolve = function() {
		if (!opts?.no_dns)
			dns.resolve_walled_garden(cfg, cfg.global.state_dir, exec);
	};

	/* ---------- CHAP ---------- */

	self.chap_for = function(mac) {
		let c = chap[mac];

		if (!c || c.expires < time()) {
			c = chap[mac] = {
				id: random_bytes(1),
				challenge: random_bytes(16),
				expires: time() + CHAP_TTL,
			};
		}

		return {
			chap_id: octal_escape(c.id),
			chap_challenge: octal_escape(c.challenge),
			chap_id_hex: hexenc(c.id),
			chap_challenge_hex: hexenc(c.challenge),
		};
	};

	function check_password(mac, user, password, chap_response) {
		if (chap_response != null && chap_response !== '') {
			let c = chap[mac];

			if (!c || c.expires < time())
				return false;

			let ok = lc(chap_response) == md5(c.id + user.password + c.challenge);

			// One use only.
			delete chap[mac];
			return ok;
		}

		// Voucher in PIN mode (password = code): the code alone is enough.
		if ((password == null || password === '') && user.batch && user.password === user.name)
			return true;

		return password != null && password === user.password;
	}

	/* ---------- lookups ---------- */

	self.client = function(ip, mac) {
		mac = normalize_mac(mac) ?? (ip ? hosts.mac_of(ip) : null);

		if (!mac)
			return null;

		auto_login(mac);

		let h = hosts.get(mac);
		let slot = by_mac[mac];

		return {
			mac,
			host: h ? hosts.view(h) : null,
			server: h?.server,
			session: slot ? self.session_view(sessions[slot]) : null,
		};
	};

	self.session_view = function(s) {
		if (!s)
			return null;

		let t = totals(s);
		let uptime = time() - s.started;
		let h = hosts.get(s.mac);

		return {
			id: s.id, slot: s.slot, user: s.user, mac: s.mac, server: s.server,
			profile: s.profile, login_by: s.login_by, started: s.started,
			uptime, uptime_text: fmt_duration(uptime),
			idle_time: time() - s.last_activity,
			session_time_left: s.limits.max_uptime ? max(0, s.limits.max_uptime - uptime) : null,
			...t,
			bytes_in_nice: fmt_bytes(t.bytes_in), bytes_out_nice: fmt_bytes(t.bytes_out),
			ipv4: h ? sort(keys(h.ip4)) : [], ipv6: h ? sort(keys(h.ip6)) : [],
			limits: s.limits,
			rate_limit: s.rate_limit ?? '',
			bursting: s.bursting,
			avg_bps: s.avg,
			auth: s.radius ? 'radius' : 'local',
			accounting: !!s.acct,
		};
	};

	self.sessions = function() {
		return map(sort(keys(sessions), (a, b) => +a - +b), (k) => self.session_view(sessions[k]));
	};

	self.hosts = function() {
		return map(hosts.list(), (h) => ({ ...h, authorized: !!by_mac[h.mac] }));
	};

	self.cookies = function() {
		let now = time();

		return {
			cookies: map(filter(keys(cookies), (t) => cookies[t].expires > now),
				(t) => ({ user: cookies[t].user, mac: cookies[t].mac, expires_in: cookies[t].expires - now })),
			mac_cookies: map(filter(keys(mac_cookies), (m) => mac_cookies[m].expires > now),
				(m) => ({ user: mac_cookies[m].user, mac: m, expires_in: mac_cookies[m].expires - now })),
		};
	};

	self.users = () => users;

	/* ---------- login / logout ---------- */

	function limits_for(profile, user, extra_uptime) {
		let up = user_profile(profile);
		let used = user?.used ?? { uptime: 0, bytes_in: 0, bytes_out: 0 };

		// Earliest of: profile session-timeout, user's remaining uptime, trial remainder.
		let max_uptime = up.session_timeout;
		for (let cand in [ user?.limit_uptime ? user.limit_uptime - used.uptime : 0, extra_uptime ?? 0 ])
			if (cand > 0 && (max_uptime == 0 || cand < max_uptime))
				max_uptime = cand;

		function left(limit, used_n) {
			return limit ? max(0, limit - used_n) : 0;
		}

		return {
			max_uptime,
			idle_timeout: up.idle_timeout,
			keepalive_timeout: up.keepalive_timeout,
			bytes_in: left(user?.limit_bytes_in, used.bytes_in),
			bytes_out: left(user?.limit_bytes_out, used.bytes_out),
			bytes_total: left(user?.limit_bytes_total, used.bytes_in + used.bytes_out),
			status_autorefresh: up.status_autorefresh,
		};
	}

	/* ---------- RADIUS authorization ---------- */

	// Access-Accept / CoA attributes -> authorization object. Only attributes
	// that are present get a key, so a CoA changes just what it carries.
	// Class values are kept hex-encoded (they are binary and must be JSON-safe).
	function parse_authz(pkt) {
		let a = {};
		let v;

		if ((v = radius.attr(pkt, 'Session-Timeout')) != null) a.session_timeout = v;
		if ((v = radius.attr(pkt, 'Idle-Timeout')) != null) a.idle_timeout = v;
		if ((v = radius.attr(pkt, 'Acct-Interim-Interval')) != null) a.interim = (v > 0) ? max(v, 10) : 0;
		if ((v = radius.attr(pkt, 'Port-Limit')) != null) a.port_limit = v;
		if ((v = radius.attr(pkt, 'Reply-Message')) != null) a.reply_message = v;
		if ((v = radius.attr(pkt, 'Filter-Id')) != null) a.filter_id = v;
		if ((v = radius.attr(pkt, 'Mikrotik-Group')) != null) a.group = v;
		if ((v = radius.attr(pkt, 'Mikrotik-Address-List')) != null) a.address_list = v;

		let cls = radius.attr(pkt, 'Class', true);
		if (length(cls))
			a.class = map(cls, (c) => hexenc(c));

		let lim = (name) => {
			let o = radius.attr(pkt, `Mikrotik-${name}-Limit`), g = radius.attr(pkt, `Mikrotik-${name}-Limit-Gigawords`);
			return (o != null || g != null) ? radius.join64(o, g) : null;
		};

		if ((v = lim('Recv')) != null) a.bytes_in = v;		// router receives = client upload
		if ((v = lim('Xmit')) != null) a.bytes_out = v;
		if ((v = lim('Total')) != null) a.bytes_total = v;

		// Rate limit precedence as on MikroTik: Mikrotik-Rate-Limit, then WISPr.
		if ((v = radius.attr(pkt, 'Mikrotik-Rate-Limit')) != null) {
			a.rate_limit = v;
		}
		else {
			let up = radius.attr(pkt, 'WISPr-Bandwidth-Max-Up'), down = radius.attr(pkt, 'WISPr-Bandwidth-Max-Down');
			if (up != null || down != null)
				a.rate_limit = `${up ?? 0}/${down ?? 0}`;
		}

		if ((v = radius.parse_iso8601(radius.attr(pkt, 'WISPr-Session-Terminate-Time'))) != null)
			a.terminate_at = v;

		if (radius.attr(pkt, 'WISPr-Session-Terminate-End-Of-Day') == 1) {
			let lt = localtime();
			let eod = time() + 86400 - (lt.hour * 3600 + lt.min * 60 + lt.sec);
			a.terminate_at = (a.terminate_at && a.terminate_at < eod) ? a.terminate_at : eod;
		}

		return a;
	}

	// RADIUS values override the profile (as on MikroTik).
	function apply_authz(limits, a, started) {
		if (!a)
			return limits;

		if (a.session_timeout != null)
			limits.max_uptime = a.session_timeout;

		if (a.terminate_at) {
			let until = max(1, a.terminate_at - started);
			if (!limits.max_uptime || until < limits.max_uptime)
				limits.max_uptime = until;
		}

		if (a.idle_timeout != null)
			limits.idle_timeout = a.idle_timeout;

		for (let k in [ 'bytes_in', 'bytes_out', 'bytes_total' ])
			if (a[k] != null)
				limits[k] = a[k];

		return limits;
	}

	// NAS/client attributes shared by Access-Request and accounting.
	function nas_attrs(server, h, id, slot) {
		let sp = server_profile_of(server);
		let ip4 = h ? sort(keys(h.ip4))[0] : null;
		let a = [
			[ 'NAS-Identifier', cfg.global.nas_identifier || 'WrtHotspot' ],
			[ 'NAS-IP-Address', dev_info[h?.dev]?.ip4 ],
			[ 'NAS-Port-Type', radius.NAS_PORT_TYPE[sp.nas_port_type] ?? 19 ],
			[ 'NAS-Port-Id', h?.dev ],
			[ 'Calling-Station-Id', radius.format_mac(h.mac, sp.radius_mac_format) ],
			[ 'Called-Station-Id', server ],
			[ 'Framed-IP-Address', ip4 ],
			[ 'Acct-Session-Id', id ],
			[ 'WISPr-Location-ID', sp.radius_location_id || null ],
			[ 'WISPr-Location-Name', sp.radius_location_name || null ],
		];

		if (slot)
			push(a, [ 'NAS-Port', slot ]);

		for (let v6 in (h ? sort(keys(h.ip6)) : []))
			if (substr(v6, 0, 4) != 'fe80')
				push(a, [ 'Framed-IPv6-Address', v6 ]);

		return a;
	}

	/* ---------- RADIUS accounting ---------- */

	function acct_enabled(server) {
		let sp = server_profile_of(server);
		return sp.use_radius && sp.radius_accounting && rad.have_servers();
	}

	function acct_send(s, status, cause) {
		if (!s.acct)
			return;

		let h = hosts.get(s.mac) ?? { mac: s.mac, dev: s.dev, ip4: {}, ip6: {} };
		let t = totals(s);
		let i = radius.split64(t.bytes_in), o = radius.split64(t.bytes_out);
		let a = [
			[ 'Acct-Status-Type', status ],
			[ 'User-Name', s.user ],
			...nas_attrs(s.server, h, s.id, s.slot),
			[ 'Acct-Authentic', s.radius ? 1 : 2 ],		// RADIUS / Local
			[ 'Event-Timestamp', time() ],
		];

		for (let c in s.radius?.class ?? [])
			push(a, [ 'Class', hexdec(c) ]);

		if (status != radius.ACCT_START)
			push(a,
				[ 'Acct-Session-Time', time() - s.started ],
				[ 'Acct-Input-Octets', i[0] ], [ 'Acct-Input-Gigawords', i[1] ],
				[ 'Acct-Output-Octets', o[0] ], [ 'Acct-Output-Gigawords', o[1] ],
				[ 'Acct-Input-Packets', t.packets_in % 4294967296 ],
				[ 'Acct-Output-Packets', t.packets_out % 4294967296 ]);

		if (status == radius.ACCT_STOP)
			push(a, [ 'Acct-Terminate-Cause', radius.TERMINATE_CAUSE[cause] ?? 10 ]);

		rad.accounting(a, null);
	}

	/* ---------- rate limits & scheduled limitations ---------- */

	function fail(code, error) {
		return { ok: false, code, error };
	}


	// 0 means unlimited: the smaller of two limits.
	function min_lim(a, b) {
		if (!a)
			return b;

		if (!b)
			return a;

		return min(a, b);
	}

	setup_shaper = function() {
		let want = cfg.global.shaper;

		if (shp && shp != 'nft')
			shp.teardown();

		shp = null;

		// Remove tc trees an earlier run may have left behind (backend switch).
		if (want != 'tc' && want != 'auto' && run('tc -V').code == 0)
			shaper.tc_backend(cfg.global.state_dir).teardown(keys(devices));

		if (want == 'off' || !length(keys(devices)))
			return;

		if (want == 'tc' || want == 'auto') {
			if (shaper.tc_available()) {
				let b = shaper.tc_backend(cfg.global.state_dir);
				let err = b.setup(keys(devices), cfg.global.shaper_capacity);

				if (!err) {
					shp = b;
					log('info', 'Rate limiting: tc HTB on %d device(s)', length(keys(devices)));
					return;
				}

				log('error', 'tc shaper: %s', err);
				b.teardown();
			}
			else if (want == 'tc') {
				log('error', 'shaper=tc but tc, sch_htb or cls_flower are not available');
			}
		}

		log('info', 'Rate limiting: nftables policing');
		shp = 'nft';
	};

	function active_limitations(profile, now) {
		let tm = localtime(now);

		return filter(map(user_profile(profile).limitations ?? [], (n) => cfg.limitations[n]),
			(l) => l && sched.window_active(l, tm));
	}

	// Scheduled limitations at login: access window, per-period quotas.
	// -> { error } or { max_uptime, bytes_in, bytes_out, bytes_total, periods }
	function limitation_check(profile, username, user, now) {
		let up = user_profile(profile);

		if (!length(up.limitations ?? []))
			return { periods: [] };

		let act = active_limitations(profile, now);

		if (!length(act))
			return { error: fail('schedule', 'access is not allowed at this time') };

		// Online until the last of the currently open windows closes.
		let tm = localtime(now);
		let left = 0, forever = false;

		for (let l in act) {
			let w = sched.window_left(l, tm);

			if (w == null)
				forever = true;
			else
				left = max(left, w);
		}

		let out = { max_uptime: forever ? 0 : left, bytes_in: 0, bytes_out: 0, bytes_total: 0, periods: [] };

		// Quotas are tracked for local users; RADIUS servers keep their own.
		if (!user)
			return out;

		for (let l in act) {
			if (!l.has_quota)
				continue;

			let start = sched.period_start(l.reset, now, l.reset_at);
			let u = users.period_used(username, l.name, start);

			if (l.uptime_limit && u.uptime >= l.uptime_limit)
				return { error: fail('uptime-limit', 'uptime limit reached for this period') };

			if ((l.download_limit && u.bytes_out >= l.download_limit) ||
			    (l.upload_limit && u.bytes_in >= l.upload_limit) ||
			    (l.transfer_limit && u.bytes_in + u.bytes_out >= l.transfer_limit))
				return { error: fail('traffic-limit', 'traffic limit reached for this period') };

			out.max_uptime = min_lim(out.max_uptime, l.uptime_limit ? l.uptime_limit - u.uptime : 0);
			out.bytes_out = min_lim(out.bytes_out, l.download_limit ? l.download_limit - u.bytes_out : 0);
			out.bytes_in = min_lim(out.bytes_in, l.upload_limit ? l.upload_limit - u.bytes_in : 0);
			out.bytes_total = min_lim(out.bytes_total, l.transfer_limit ? l.transfer_limit - u.bytes_in - u.bytes_out : 0);
			push(out.periods, { name: l.name, start });
		}

		return out;
	}

	// The rate limit in force: RADIUS/CoA, else the first active scheduled
	// limitation with one, else the user profile.
	function session_rate(s) {
		if (s.radius?.rate_limit)
			return s.radius.rate_limit;

		for (let l in active_limitations(s.profile, time()))
			if (l.rate_limit)
				return l.rate_limit;

		return user_profile(s.profile).rate_limit ?? '';
	}

	function apply_rate(s, force) {
		let str = session_rate(s);
		let p = shaper.parse_rate_limit(str);

		if (str != '' && !p && s.rate_limit != str)
			log('warn', 'Ignoring invalid rate limit "%s" for %s', str, s.user);

		s.rate_limit = str;

		if (!shp)
			return;

		// Burst is allowed until the window average says otherwise.
		s.bursting ??= { rx: true, tx: true };

		let ceil = p ? { rx: shaper.effective_ceil(p.rx, s.bursting.rx), tx: shaper.effective_ceil(p.tx, s.bursting.tx) } : null;
		let key = p ? sprintf('%s|%d|%d', str, ceil.rx, ceil.tx) : '';

		if (!force && key == (s.shaped ?? ''))
			return;

		s.shaped = key;

		if (shp == 'nft') {
			s.nft_lim = p ? { up: shaper.nft_limit(ceil.rx), down: shaper.nft_limit(ceil.tx) } : null;
			exec(nft.session_limit_cmds(s.slot, s.nft_lim));
			return;
		}

		if (s.nft_lim) {
			s.nft_lim = null;
			exec(nft.session_limit_cmds(s.slot, null));
		}

		let err = p ? shp.set_session(s.dev, s.slot, s.mac, p, ceil) : shp.del_session(s.dev, s.slot);

		if (err)
			log('warn', 'Rate limit for %s: %s', s.user, err);
	}

	function remove_rate(s) {
		if (shp && shp != 'nft')
			shp.del_session(s.dev, s.slot);
	}

	reapply_rates = function() {
		for (let slot, s in sessions)
			apply_rate(s, true);
	};

	// MikroTik burst: average over burst-time below burst-threshold -> burst
	// rate allowed, otherwise max-limit. Also picks up rate changes (CoA,
	// limitation windows opening or closing).
	function shape_poll(s, now) {
		let p = shaper.parse_rate_limit(s.rate_limit);

		if (p && (p.rx.burst_rate > p.rx.rate || p.tx.burst_rate > p.tx.rate)) {
			let t = totals(s);
			let win = max(p.rx.burst_time, p.tx.burst_time);

			s.bh ??= [ [ s.started, 0, 0 ] ];
			push(s.bh, [ now, t.bytes_in, t.bytes_out ]);

			while (length(s.bh) > 2 && now - s.bh[1][0] > win)
				shift(s.bh);

			let rx = shaper.window_avg(map(s.bh, (x) => [ x[0], x[1] ]), p.rx.burst_time, now);
			let tx = shaper.window_avg(map(s.bh, (x) => [ x[0], x[2] ]), p.tx.burst_time, now);

			s.bursting = { rx: shaper.burst_allowed(p.rx, rx), tx: shaper.burst_allowed(p.tx, tx) };
			s.avg = { rx, tx };
		}

		apply_rate(s, false);
	}

	/* ---------- sessions ---------- */

	// authz: RADIUS authorization (null for local users); id: Acct-Session-Id
	// already sent in the Access-Request.
	function start_session(mac, server, username, profile, login_by, extra_uptime, user, authz, id) {
		let old = by_mac[mac];
		if (old)
			self.logout(old, CAUSE.NEW_LOGIN);

		let slot = alloc_slot();
		if (!slot)
			return [ null, 'no free session slots' ];

		let h = hosts.get(mac);
		let sp = server_profile_of(server);
		let now = time();
		let interim = (sp.radius_interim_update == 'received') ? (authz?.interim ?? 0) : sp.radius_interim_update;
		let s = {
			slot, mac, server, user: username, profile, login_by,
			id: id ?? random_hex(4),
			dev: h?.dev,
			started: now, last_activity: now, last_seen: now,
			base: { up_bytes: 0, up_packets: 0, down_bytes: 0, down_packets: 0 },
			k: { up_bytes: 0, up_packets: 0, down_bytes: 0, down_packets: 0 },
			limits: apply_authz(limits_for(profile, user, extra_uptime), authz, now),
			radius: authz,
			rate_limit: authz?.rate_limit ?? user_profile(profile).rate_limit,
			acct: acct_enabled(server),
			interim,
			next_interim: interim ? now + interim : 0,
		};

		let lc = limitation_check(profile, username, user, now);

		if (lc.error)
			return [ null, lc.error ];

		s.limits.max_uptime = min_lim(s.limits.max_uptime, lc.max_uptime);
		s.limits.bytes_in = min_lim(s.limits.bytes_in, lc.bytes_in);
		s.limits.bytes_out = min_lim(s.limits.bytes_out, lc.bytes_out);
		s.limits.bytes_total = min_lim(s.limits.bytes_total, lc.bytes_total);
		s.periods = lc.periods;

		let err = exec(nft.session_add_cmds(slot, mac));
		if (err)
			return [ null, 'dataplane error' ];

		sessions[slot] = s;
		by_mac[mac] = slot;
		checkpoint();

		log('info', 'Login %s (%s) on %s by %s%s', username, mac, server, login_by, authz ? ' (RADIUS)' : '');
		event('login', { user: username, mac, server, session_id: s.id, login_by });
		run_hook(user_profile(profile).on_login, hook_env(s));
		acct_send(s, radius.ACCT_START);
		apply_rate(s, true);

		return [ s, null ];
	}

	// Last step of every user login: concurrent-session limit, session,
	// cookies. `authz` is set for RADIUS users.
	function finish_login(mac, server, username, profile, method, user, authz, id) {
		let limit = (authz?.port_limit != null) ? authz.port_limit : user_profile(profile).shared_users;
		let active = filter(values(sessions), (s) => s.user == username && s.mac != mac);

		if (limit > 0 && length(active) >= limit)
			return fail('shared-users', 'no more sessions are allowed for this user');

		let res = start_session(mac, server, username, profile, method, 0, user, authz, id);

		if (!res[0])
			return (type(res[1]) == 'object') ? res[1] : fail('internal', res[1]);

		let out = { ok: true, session: self.session_view(res[0]) };

		if (authz?.reply_message)
			out.message = authz.reply_message;

		// Cookie logins don't mint new cookies; credential logins may.
		if (method != 'cookie' && method != 'mac-cookie') {
			let token = issue_cookies(mac, server, username, profile, authz);

			if (token)
				out.cookie = { token, max_age: server_profile_of(server).http_cookie_lifetime };
		}

		return out;
	}

	// Account checks for local users.
	function authorize_user(mac, server, username, method) {
		let user = users.get(username);

		if (!user)
			return fail('invalid', 'invalid username or password');

		if (user.disabled)
			return fail('disabled', 'user is disabled');

		if (user.server && user.server != 'all' && user.server != server)
			return fail('server', 'user is not allowed on this server');

		if (user.mac && user.mac != mac)
			return fail('mac', 'user is bound to another device');

		let used = user.used ?? { uptime: 0, bytes_in: 0, bytes_out: 0 };

		if (user.limit_uptime && used.uptime >= user.limit_uptime)
			return fail('uptime-limit', 'uptime limit reached');

		if ((user.limit_bytes_in && used.bytes_in >= user.limit_bytes_in) ||
		    (user.limit_bytes_out && used.bytes_out >= user.limit_bytes_out) ||
		    (user.limit_bytes_total && used.bytes_in + used.bytes_out >= user.limit_bytes_total))
			return fail('traffic-limit', 'traffic limit reached');

		let now = time();

		if (user.expires && now >= user.expires)
			return fail('expired', 'this voucher has expired');

		let res = finish_login(mac, server, username, user.profile, method, user, null);

		if (!res.ok)
			return res;

		// First use: a voucher's validity starts now and it counts as sold.
		if (!user.first_login) {
			let upd = { first_login: now };

			if (user.validity && !user.expires)
				upd.expires = now + user.validity;

			users.set_internal(username, upd);
			users.save(true);

			if (user.batch || user.price)
				records.add_sale({ time: now, user: username, batch: user.batch ?? '', price: user.price ?? '', profile: user.profile });
		}

		let s = sessions[res.session.slot];

		if (user.expires && s) {
			s.limits.max_uptime = min_lim(s.limits.max_uptime, user.expires - s.started);
			res.session = self.session_view(s);
		}

		return res;
	}

	function radius_profile(authz) {
		return (authz?.group && cfg.user_profiles[authz.group]) ? authz.group : 'default';
	}

	// Cookie / MAC-cookie: local users are re-checked, RADIUS users get their
	// stored authorization replayed (with fresh accounting).
	function cookie_login(mac, server, entry, method) {
		if (users.get(entry.user) || !entry.radius)
			return authorize_user(mac, server, entry.user, method);

		return finish_login(mac, server, entry.user, radius_profile(entry.radius), method, null, entry.radius);
	}

	// MAC-cookie: log a returning device back in without any page.
	try_mac_cookie = function(mac) {
		if (by_mac[mac] || !mac_cookies[mac])
			return null;

		let mc = mac_cookies[mac];
		let h = hosts.get(mac);

		if (mc.expires < time() || !h?.server || !('mac-cookie' in server_profile_of(h.server).login_by)) {
			delete mac_cookies[mac];
			cookies_dirty = true;
			return null;
		}

		let res = cookie_login(mac, h.server, mc, 'mac-cookie');

		// Failed MAC-cookie logins remove the cookie (MikroTik does the same).
		if (!res.ok) {
			log('info', 'MAC-cookie login for %s (%s) refused: %s', mc.user, mac, res.error);
			delete mac_cookies[mac];
			cookies_dirty = true;
		}

		return res;
	};

	// A device without a session showed up: MAC cookie first, then MAC
	// authentication (login_by mac), at most once a minute per device so a
	// rejected MAC can't flood the RADIUS server.
	auto_login = function(mac) {
		if (by_mac[mac])
			return;

		if (mac_cookies[mac]) {
			try_mac_cookie(mac);

			if (by_mac[mac])
				return;
		}

		let h = hosts.get(mac);

		if (!h?.server || !('mac' in server_profile_of(h.server).login_by))
			return;

		if (time() - (mac_tried[mac] ?? 0) < 60)
			return;

		mac_tried[mac] = time();

		let report = (res) => {
			if (res && !res.ok)
				log('debug', 'MAC login of %s refused: %s', mac, res.error);
		};

		report(self.login({ mac, method: 'mac' }, report));
	};

	// Access-Request for a user we don't have locally. done(result) is
	// called once the server answers (or all servers timed out).
	function radius_login(mac, server, sp, username, password, chap_response, method, done) {
		let h = hosts.get(mac);
		let id = random_hex(4);
		let attrs = [
			[ 'User-Name', username ],
			[ 'Service-Type', 1 ],		// Login-User
			...nas_attrs(server, h, id),
		];

		if (method == 'http-chap') {
			let c = chap[mac];

			if (!c || c.expires < time() || !match(chap_response ?? '', /^[0-9a-fA-F]{32}$/))
				return done(fail('invalid', 'invalid username or password'));

			delete chap[mac];
			push(attrs, [ 'CHAP-Password', c.id + hexdec(chap_response) ], [ 'CHAP-Challenge', c.challenge ]);
		}
		else {
			push(attrs, [ 'User-Password', password ?? '' ]);
		}

		rad.authenticate(attrs, (pkt, err) => {
			if (!pkt) {
				log('warn', 'RADIUS login of %s (%s): %s', username, mac, err);
				return done(fail('radius-timeout', 'authentication server is not responding, try again later'));
			}

			if (pkt.code == radius.CODE.ACCESS_ACCEPT) {
				let authz = parse_authz(pkt);
				return done(finish_login(mac, server, username, radius_profile(authz), method, null, authz, id));
			}

			if (pkt.code == radius.CODE.ACCESS_CHALLENGE)
				return done(fail('invalid', 'challenge-response authentication is not supported'));

			done(fail('invalid', radius.attr(pkt, 'Reply-Message') ?? 'invalid username or password'));
		});
	}

	// req: { ip?, mac?, method, username?, password?, chap_response?, cookie? }
	// Returns { ok, session?, cookie?, message?, error?, code? }, or null when
	// the answer depends on a RADIUS server: then done(result) follows.
	self.login = function(req, done) {
		let mac = normalize_mac(req.mac) ?? (req.ip ? hosts.mac_of(req.ip) : null);

		if (!mac)
			return fail('no-host', 'unknown client (no neighbor entry)');

		let h = hosts.get(mac);
		let server = h?.server;

		if (!server)
			return fail('no-server', 'client is not on a hotspot interface');

		let sp = server_profile_of(server);
		let method = req.method ?? ((req.chap_response ?? '') !== '' ? 'http-chap' : 'http-pap');

		// "https" is a transport for the PAP form, not a separate credential check.
		let enabled = (method == 'http-pap' && 'https' in sp.login_by) || (method in sp.login_by);

		if (!enabled)
			return fail('method', `login method ${method} is not enabled`);

		if (method == 'trial') {
			let t = trials[mac];
			let now = time();

			if (!t || now - t.window_start >= sp.trial_uptime_reset)
				t = trials[mac] = { used: 0, window_start: now };

			let remaining = sp.trial_uptime_limit - t.used;

			if (remaining <= 0)
				return fail('trial-expired', 'free trial used up, try again later');

			let res = start_session(mac, server, `T-${mac}`, sp.trial_user_profile, 'trial', remaining, null);

			if (!res[0])
				return (type(res[1]) == 'object') ? res[1] : fail('internal', res[1]);

			return { ok: true, session: self.session_view(res[0]) };
		}

		if (method == 'cookie') {
			let c = cookies[req.cookie ?? ''];

			if (!c || c.expires < time() || c.mac != mac) {
				if (c && c.mac != mac)
					log('warn', 'Cookie of %s presented by %s, ignored', c.mac, mac);

				return fail('cookie', 'cookie expired or invalid');
			}

			let res = cookie_login(mac, server, c, 'cookie');

			if (!res.ok) {
				delete cookies[req.cookie];
				cookies_dirty = true;
			}

			return res;
		}

		if (method == 'mac-cookie')
			return try_mac_cookie(mac) ?? fail('cookie', 'no MAC cookie');

		let username = req.username;
		let password = req.password;

		if (method == 'mac') {
			username = users.get(mac) ? mac : radius.format_mac(mac, sp.radius_mac_format);
			password = sp.mac_auth_password;
		}

		if (sp.split_user_domain && username) {
			let m = match(username, /^([^@\\]+)@(.+)$/) ?? match(username, /^(.+)\\([^\\]+)$/);
			if (m)
				username = index(username, '@') >= 0 ? m[1] : m[2];
		}

		let user = users.get(username);

		// Local users first; unknown users go to RADIUS when enabled.
		if (!user && sp.use_radius && rad.have_servers()) {
			let sync = true, result = null;

			radius_login(mac, server, sp, username, password, req.chap_response, method, (res) => {
				if (sync)
					result = res;
				else if (done)
					done(res);
			});

			sync = false;
			return result;
		}

		if (!user || !check_password(mac, user, password, (method == 'http-chap') ? req.chap_response : null))
			return fail('invalid', 'invalid username or password');

		return authorize_user(mac, server, username, method);
	};

	/* ---------- RFC 5176 CoA / Disconnect ---------- */

	self.coa = function(pkt, srv) {
		let is_disc = (pkt.code == radius.CODE.DISCONNECT_REQUEST);
		let nak = is_disc ? radius.CODE.DISCONNECT_NAK : radius.CODE.COA_NAK;
		let sid = radius.attr(pkt, 'Acct-Session-Id');
		let user = radius.attr(pkt, 'User-Name');
		let csid = radius.attr(pkt, 'Calling-Station-Id');
		let fip = radius.attr(pkt, 'Framed-IP-Address');
		let mac = csid ? normalize_mac(lc(replace(csid, /[^0-9A-Fa-f]/g, ''))) : null;
		let fmac = fip ? hosts.mac_of(fip) : null;

		if (!sid && !user && !mac && !fip)
			return [ nak, [ [ 'Error-Cause', 402 ] ] ];		// Missing-Attribute

		let matched = filter(values(sessions), (s) =>
			(!sid || s.id == sid) && (!user || s.user == user) && (!mac || s.mac == mac) && (!fip || s.mac == fmac));

		if (!length(matched)) {
			log('info', 'RADIUS %s from %s: no matching session', is_disc ? 'Disconnect' : 'CoA', srv.address);
			return [ nak, [ [ 'Error-Cause', 503 ] ] ];		// Session-Context-Not-Found
		}

		if (is_disc) {
			log('info', 'RADIUS Disconnect from %s: %d session(s)', srv.address, length(matched));
			self.logout_many(map(matched, (s) => [ s.slot, CAUSE.ADMIN ]));
			return [ radius.CODE.DISCONNECT_ACK, [] ];
		}

		let a = parse_authz(pkt);

		for (let s in matched) {
			s.radius = { ...(s.radius ?? {}), ...a };

			if (a.group && cfg.user_profiles[a.group]) {
				let up = user_profile(a.group);
				s.profile = a.group;
				s.limits.idle_timeout = up.idle_timeout;
				s.limits.keepalive_timeout = up.keepalive_timeout;
				s.rate_limit = up.rate_limit;
			}

			apply_authz(s.limits, a, s.started);

			if (a.rate_limit != null)
				s.rate_limit = a.rate_limit;

			if (a.interim) {
				s.interim = a.interim;
				s.next_interim = time() + a.interim;
			}

			apply_rate(s, false);
		}

		log('info', 'RADIUS CoA from %s applied to %d session(s)', srv.address, length(matched));
		checkpoint();
		return [ radius.CODE.COA_ACK, [] ];
	};

	function finish(s, cause) {
		let t = totals(s);
		let uptime = time() - s.started;

		if (s.login_by == 'trial') {
			let tr = trials[s.mac];
			if (tr)
				tr.used += uptime;
		}
		else {
			users.add_usage(s.user, uptime, t.bytes_in, t.bytes_out);

			for (let p in s.periods ?? [])
				users.add_period_usage(s.user, p.name, p.start, uptime, t.bytes_in, t.bytes_out);
		}

		if (!(cause in COOKIE_KEEP))
			drop_cookies(s.mac);

		let h = hosts.get(s.mac);
		records.add_session({
			start: s.started, end: time(), user: s.user, mac: s.mac,
			ipv4: h ? (sort(keys(h.ip4))[0] ?? '') : '', ipv6: h ? length(keys(h.ip6)) : 0,
			server: s.server, profile: s.profile, login_by: s.login_by, auth: s.radius ? 'radius' : 'local',
			batch: users.get(s.user)?.batch ?? '', uptime, bytes_in: t.bytes_in, bytes_out: t.bytes_out, cause,
		});

		acct_send(s, radius.ACCT_STOP, cause);

		log('info', 'Logout %s (%s): %s, %s, in %d / out %d bytes', s.user, s.mac, cause, fmt_duration(uptime), t.bytes_in, t.bytes_out);
		event('logout', { user: s.user, mac: s.mac, server: s.server, session_id: s.id, cause, uptime, ...t });
		run_hook(user_profile(s.profile).on_logout, hook_env(s, cause));
	}

	// Log out one or more slots with a single nft batch.
	self.logout_many = function(list) {
		let cmds = [];

		// Final counter read so the last seconds of traffic are billed.
		let kc = nft.read_counters();

		for (let item in list) {
			let s = sessions[item[0]];
			if (!s)
				continue;

			if (kc?.[s.slot])
				s.k = kc[s.slot];

			finish(s, item[1]);
			remove_rate(s);
			push(cmds, ...nft.session_del_cmds(s.slot, s.mac));
			delete by_mac[s.mac];
			delete sessions[s.slot];
		}

		exec(cmds);
		checkpoint();		// RAM; user usage reaches flash on the db_sync timer
		save_cookies(false);
		return length(cmds) > 0;
	};

	self.logout = function(slot, cause) {
		return self.logout_many([ [ slot, cause ?? CAUSE.USER ] ]);
	};

	self.logout_where = function(sel, cause) {
		let mac = normalize_mac(sel.mac) ?? (sel.ip ? hosts.mac_of(sel.ip) : null);
		let list = [];

		for (let slot, s in sessions)
			if ((mac && s.mac == mac) || (sel.id && s.id == sel.id) || (sel.user && s.user == sel.user))
				push(list, [ slot, cause ?? CAUSE.ADMIN ]);

		self.logout_many(list);
		return length(list);
	};

	self.cookie_remove = function(sel) {
		let mac = normalize_mac(sel.mac);
		let n = 0;

		for (let t, c in cookies)
			if ((mac && c.mac == mac) || (sel.user && c.user == sel.user)) {
				delete cookies[t];
				n++;
			}

		for (let m, c in mac_cookies)
			if ((mac && m == mac) || (sel.user && c.user == sel.user)) {
				delete mac_cookies[m];
				n++;
			}

		cookies_dirty = true;
		save_cookies(true);
		return n;
	};

	/* ---------- periodic work ---------- */

	self.poll = function() {
		let kc = nft.read_counters();

		if (kc == null || need_rebuild) {
			log('warn', 'Dataplane table missing or stale, rebuilding');
			self.rebuild();
			kc = nft.read_counters() ?? {};
		}

		let now = time();
		let expired = [];

		for (let slot, s in sessions) {
			let k = kc[slot];

			if (k) {
				if (k.up_bytes != s.k.up_bytes)
					s.last_activity = s.last_seen = now;

				s.k = k;
			}
			else {
				// Counter vanished (e.g. partial flush): force a rebuild next round.
				need_rebuild = true;
			}

			if (s.acct && s.interim && now >= s.next_interim) {
				acct_send(s, radius.ACCT_INTERIM);
				s.next_interim = now + s.interim;
			}

			shape_poll(s, now);

			let t = totals(s);
			let l = s.limits;
			let uptime = now - s.started;
			let cause = null;

			if (l.max_uptime && uptime >= l.max_uptime)
				cause = s.limits.max_uptime == user_profile(s.profile).session_timeout ? CAUSE.SESSION_TIMEOUT : CAUSE.UPTIME_LIMIT;
			else if (l.idle_timeout && now - s.last_activity >= l.idle_timeout)
				cause = CAUSE.IDLE_TIMEOUT;
			else if (l.keepalive_timeout && now - s.last_seen >= l.keepalive_timeout)
				cause = CAUSE.KEEPALIVE_TIMEOUT;
			else if ((l.bytes_in && t.bytes_in >= l.bytes_in) ||
			         (l.bytes_out && t.bytes_out >= l.bytes_out) ||
			         (l.bytes_total && t.bytes_in + t.bytes_out >= l.bytes_total))
				cause = CAUSE.TRAFFIC_LIMIT;

			if (cause)
				push(expired, [ slot, cause ]);
		}

		if (length(expired))
			self.logout_many(expired);
		else
			checkpoint();

		// Interfaces re-created by netifd lose their qdiscs: rebuild then.
		if (shp && shp != 'nft' && (++polls % 6) == 0) {
			for (let dev in keys(devices)) {
				if (!shp.healthy(dev)) {
					log('warn', 'Shaper on %s is gone, rebuilding', dev);
					setup_shaper();
					reapply_rates();
					break;
				}
			}
		}

		// Forget unauthorized hosts after the server's idle-timeout.
		hosts.prune((server) => cfg.servers[server]?.idle_timeout ?? 0, (mac) => !!by_mac[mac]);

		for (let mac, c in chap)
			if (c.expires < now)
				delete chap[mac];
	};

	self.sync_db = function() {
		users.save(false);
		save_cookies(false);
		records.save(false);
	};

	self.records = () => records;

	/* ---------- startup / shutdown ---------- */

	function restore() {
		let st = read_json(state_path('sessions.json'));

		if (!st)
			return;

		trials = st.trials ?? {};
		next_slot = st.next_slot ?? 1;

		// Counters still in the kernel if only the daemon restarted.
		let kc = nft.read_counters();

		for (let s in st.sessions ?? []) {
			if (!s.slot || !normalize_mac(s.mac))
				continue;

			if (kc?.[s.slot])
				s.k = kc[s.slot];

			sessions[s.slot] = s;
			by_mac[s.mac] = s.slot;
			hosts.touch(s.mac, s.dev);
		}

		log('info', 'Restored %d session(s)', length(keys(sessions)));
	}

	self.start = function() {
		cfg = load_config(confdir);
		set_log_level(cfg.global.log_level);
		mkdir_p(cfg.global.state_dir);

		users = users_db.create(cfg.global.db_dir);
		log('info', 'Loaded %d user(s)', users.load());
		load_cookies();

		records = records_mod.create(cfg.global.db_dir, cfg.global.history_size);
		records.load();

		hosts = hosts_mod.create({
			on_seen: (h) => {
				let slot = by_mac[h.mac];
				if (slot)
					sessions[slot].last_seen = time();
			},
			// A device we have a MAC cookie for showed up again.
			on_update: (h) => {
				if (!by_mac[h.mac])
					auto_login(h.mac);
			},
		});

		devices = resolve_devices();
		hosts.set_devices(devices);
		setup_radius();
		restore();

		let err = self.rebuild();
		apply_dns();
		setup_shaper();
		reapply_rates();

		if (opts?.no_netlink != true)
			hosts.start();

		return err;
	};

	// On a clean stop we keep sessions (and the table) so clients stay online
	// across restarts and upgrades; `flush` removes everything.
	self.stop = function() {
		checkpoint();
		users.save(true);
		save_cookies(true);
		records.save(true);
	};

	self.flush = function() {
		let list = map(keys(sessions), (slot) => [ slot, CAUSE.NAS_REBOOT ]);
		self.logout_many(list);
		nft.delete_table();

		if (shp && shp != 'nft')
			shp.teardown();

		shp = null;
		need_rebuild = true;
	};

	// For tests.
	self._hosts = () => hosts;

	return self;
};
