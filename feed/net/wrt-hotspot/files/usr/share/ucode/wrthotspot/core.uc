// hotspotd core: sessions (MikroTik /ip hotspot active), login methods,
// limits, accounting and crash/restart recovery.
'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';
import { md5 } from 'digest';
import * as nft from 'wrthotspot.nft';
import * as users_db from 'wrthotspot.users';
import * as hosts_mod from 'wrthotspot.hosts';
import { load as load_config } from 'wrthotspot.config';
import {
	log, set_log_level, normalize_mac, normalize_ip, random_bytes, random_hex,
	read_json, write_atomic, mkdir_p, fmt_duration, fmt_bytes
} from 'wrthotspot.util';

export const VERSION = '0.1.0';

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
	let users;
	let hosts;
	let need_rebuild = true;

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

	/* ---------- configuration & devices ---------- */

	function resolve_devices() {
		let devs = {};

		for (let name, srv in cfg.servers) {
			if (!srv.enabled)
				continue;

			let dev = srv.device;

			if (!dev && srv.interface && conn) {
				let st = conn.call(`network.interface.${srv.interface}`, 'status');
				dev = st?.l3_device ?? st?.device;
			}

			if (!dev) {
				log('warn', 'Server %s: interface %s has no device yet', name, srv.interface);
				continue;
			}

			devs[dev] = name;
		}

		return devs;
	}

	self.reload = function() {
		cfg = load_config(confdir);
		set_log_level(cfg.global.log_level);
		mkdir_p(cfg.global.state_dir);

		let devs = resolve_devices();
		let changed = sprintf('%J', devs) != sprintf('%J', devices);

		devices = devs;

		if (hosts)
			hosts.set_devices(devices);

		if (changed)
			need_rebuild = true;

		return self.rebuild();
	};

	self.devices = () => devices;
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
			port: cfg.global.portal_port,
			sessions: map(values(sessions), (s) => ({ slot: s.slot, mac: s.mac })),
			bypass: [], block: [], wg4: [], wg6: [],
		});

		let err = nft.apply(text, cfg.global.state_dir);

		if (err) {
			need_rebuild = true;
			return err;
		}

		need_rebuild = false;
		checkpoint();
		log('info', 'Dataplane built: %d device(s), %d session(s)', length(keys(devices)), length(keys(sessions)));
		return null;
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

		return password != null && password === user.password;
	}

	/* ---------- lookups ---------- */

	self.client = function(ip, mac) {
		mac = normalize_mac(mac) ?? (ip ? hosts.mac_of(ip) : null);

		if (!mac)
			return null;

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
		};
	};

	self.sessions = function() {
		return map(sort(keys(sessions), (a, b) => +a - +b), (k) => self.session_view(sessions[k]));
	};

	self.hosts = function() {
		return map(hosts.list(), (h) => ({ ...h, authorized: !!by_mac[h.mac] }));
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

	function start_session(mac, server, username, profile, login_by, extra_uptime, user) {
		let old = by_mac[mac];
		if (old)
			self.logout(old, CAUSE.NEW_LOGIN);

		let slot = alloc_slot();
		if (!slot)
			return [ null, 'no free session slots' ];

		let h = hosts.get(mac);
		let now = time();
		let s = {
			slot, mac, server, user: username, profile, login_by,
			id: random_hex(4),
			dev: h?.dev,
			started: now, last_activity: now, last_seen: now,
			base: { up_bytes: 0, up_packets: 0, down_bytes: 0, down_packets: 0 },
			k: { up_bytes: 0, up_packets: 0, down_bytes: 0, down_packets: 0 },
			limits: limits_for(profile, user, extra_uptime),
		};

		let err = exec(nft.session_add_cmds(slot, mac));
		if (err)
			return [ null, 'dataplane error' ];

		sessions[slot] = s;
		by_mac[mac] = slot;
		checkpoint();

		log('info', 'Login %s (%s) on %s by %s', username, mac, server, login_by);
		event('login', { user: username, mac, server, session_id: s.id, login_by });
		run_hook(user_profile(profile).on_login, hook_env(s));

		return [ s, null ];
	}

	// req: { ip?, mac?, method, username?, password?, chap_response? }
	// Returns { ok, session?, error?, code? }.
	self.login = function(req) {
		let mac = normalize_mac(req.mac) ?? (req.ip ? hosts.mac_of(req.ip) : null);

		if (!mac)
			return { ok: false, code: 'no-host', error: 'unknown client (no neighbor entry)' };

		let h = hosts.get(mac);
		let server = h?.server;

		if (!server)
			return { ok: false, code: 'no-server', error: 'client is not on a hotspot interface' };

		let sp = server_profile_of(server);
		let method = req.method ?? ((req.chap_response ?? '') !== '' ? 'http-chap' : 'http-pap');

		if (!(method in sp.login_by))
			return { ok: false, code: 'method', error: `login method ${method} is not enabled` };

		if (method == 'trial') {
			let t = trials[mac];
			let now = time();

			if (!t || now - t.window_start >= sp.trial_uptime_reset)
				t = trials[mac] = { used: 0, window_start: now };

			let remaining = sp.trial_uptime_limit - t.used;

			if (remaining <= 0)
				return { ok: false, code: 'trial-expired', error: 'free trial used up, try again later' };

			let res = start_session(mac, server, `T-${mac}`, sp.trial_user_profile, 'trial', remaining, null);
			return res[0] ? { ok: true, session: self.session_view(res[0]) } : { ok: false, code: 'internal', error: res[1] };
		}

		let username = req.username;
		let password = req.password;

		if (method == 'mac') {
			username = mac;
			password = sp.mac_auth_password;
		}

		if (sp.split_user_domain && username) {
			let m = match(username, /^([^@\\]+)@(.+)$/) ?? match(username, /^(.+)\\([^\\]+)$/);
			if (m)
				username = index(username, '@') >= 0 ? m[1] : m[2];
		}

		let user = users.get(username);

		if (!user || !check_password(mac, user, password, (method == 'http-chap') ? req.chap_response : null))
			return { ok: false, code: 'invalid', error: 'invalid username or password' };

		if (user.disabled)
			return { ok: false, code: 'disabled', error: 'user is disabled' };

		if (user.server && user.server != 'all' && user.server != server)
			return { ok: false, code: 'server', error: 'user is not allowed on this server' };

		if (user.mac && user.mac != mac)
			return { ok: false, code: 'mac', error: 'user is bound to another device' };

		let used = user.used ?? { uptime: 0, bytes_in: 0, bytes_out: 0 };

		if (user.limit_uptime && used.uptime >= user.limit_uptime)
			return { ok: false, code: 'uptime-limit', error: 'uptime limit reached' };

		if ((user.limit_bytes_in && used.bytes_in >= user.limit_bytes_in) ||
		    (user.limit_bytes_out && used.bytes_out >= user.limit_bytes_out) ||
		    (user.limit_bytes_total && used.bytes_in + used.bytes_out >= user.limit_bytes_total))
			return { ok: false, code: 'traffic-limit', error: 'traffic limit reached' };

		let up = user_profile(user.profile);
		let active = filter(values(sessions), (s) => s.user == username && s.mac != mac);

		if (up.shared_users > 0 && length(active) >= up.shared_users)
			return { ok: false, code: 'shared-users', error: 'no more sessions are allowed for this user' };

		let res = start_session(mac, server, username, user.profile, method, 0, user);
		return res[0] ? { ok: true, session: self.session_view(res[0]) } : { ok: false, code: 'internal', error: res[1] };
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
		}

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
			push(cmds, ...nft.session_del_cmds(s.slot, s.mac));
			delete by_mac[s.mac];
			delete sessions[s.slot];
		}

		exec(cmds);
		checkpoint();		// RAM; user usage reaches flash on the db_sync timer
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

		// Forget unauthorized hosts after the server's idle-timeout.
		hosts.prune((server) => cfg.servers[server]?.idle_timeout ?? 0, (mac) => !!by_mac[mac]);

		for (let mac, c in chap)
			if (c.expires < now)
				delete chap[mac];
	};

	self.sync_db = function() {
		users.save(false);
	};

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

		hosts = hosts_mod.create({
			on_seen: (h) => {
				let slot = by_mac[h.mac];
				if (slot)
					sessions[slot].last_seen = time();
			},
		});

		devices = resolve_devices();
		hosts.set_devices(devices);
		restore();

		if (opts?.no_netlink != true)
			hosts.start();

		return self.rebuild();
	};

	// On a clean stop we keep sessions (and the table) so clients stay online
	// across restarts and upgrades; `flush` removes everything.
	self.stop = function() {
		checkpoint();
		users.save(true);
	};

	self.flush = function() {
		let list = map(keys(sessions), (slot) => [ slot, CAUSE.NAS_REBOOT ]);
		self.logout_many(list);
		nft.delete_table();
		need_rebuild = true;
	};

	// For tests.
	self._hosts = () => hosts;

	return self;
};
