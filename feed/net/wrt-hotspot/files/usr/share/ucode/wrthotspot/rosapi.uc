// RouterOS API subset (TCP 8728) so that billing systems written for MikroTik
// (SAS4, Radius Manager, Splynx, ...) can list online users, disconnect them
// and manage hotspot users. Off by default; clients must come from an allowed
// address and log in. Ships with wrt-hotspot-radius (loaded with require()).
//
// Protocol: sentences of length-prefixed words ending with an empty word;
// replies !re / !done / !trap / !fatal. Both the plain login (RouterOS 6.43+)
// and the old MD5 challenge login are accepted.
'use strict';

import * as socket from 'socket';
import * as uloop from 'uloop';
import * as fs from 'fs';
import * as rtnl from 'rtnl';
import { md5 } from 'digest';
import { log, random_bytes } from 'wrthotspot.util';
import { parse_rate_limit } from 'wrthotspot.shaper';
import { verify as operator_verify } from 'wrthotspot.operators';

const MAX_CONN = 8;
const IDLE_CLOSE = 600;		// seconds without a request
const MAX_SENTENCE = 65536;
const FAIL_LIMIT = 5, FAIL_WINDOW = 60;	// failed logins per address, seconds

/* ---------- wire format ---------- */

function enc_len(n) {
	if (n < 0x80)
		return chr(n);
	if (n < 0x4000)
		return chr(0x80 | (n >> 8), n & 0xff);
	if (n < 0x200000)
		return chr(0xc0 | (n >> 16), (n >> 8) & 0xff, n & 0xff);
	if (n < 0x10000000)
		return chr(0xe0 | (n >> 24), (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff);

	return chr(0xf0, (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff);
}

// [ length, bytes used ] or null when more data is needed; length -1 = invalid.
function dec_len(buf, i) {
	let n = length(buf);

	if (i >= n)
		return null;

	let c = ord(buf, i);
	let need = ((c & 0x80) == 0) ? 1 : ((c & 0xc0) == 0x80) ? 2 : ((c & 0xe0) == 0xc0) ? 3
		: ((c & 0xf0) == 0xe0) ? 4 : (c == 0xf0) ? 5 : 0;

	if (!need)
		return [ -1, 1 ];

	if (i + need > n)
		return null;

	let b = (k) => ord(buf, i + k);

	switch (need) {
	case 1: return [ c, 1 ];
	case 2: return [ ((c & 0x3f) << 8) | b(1), 2 ];
	case 3: return [ ((c & 0x1f) << 16) | (b(1) << 8) | b(2), 3 ];
	case 4: return [ ((c & 0x0f) << 24) | (b(1) << 16) | (b(2) << 8) | b(3), 4 ];
	default: return [ (b(1) << 24) | (b(2) << 16) | (b(3) << 8) | b(4), 5 ];
	}
}

function sentence(words) {
	let out = '';

	for (let w in words)
		out += enc_len(length(w)) + w;

	return out + chr(0);
}

// Next complete sentence from buf: [ words, bytes used ], null = incomplete,
// [ null, n ] = garbage (close the connection).
function next_sentence(buf) {
	let words = [], i = 0;

	while (true) {
		let l = dec_len(buf, i);

		if (l == null)
			return null;

		if (l[0] < 0 || l[0] > MAX_SENTENCE)
			return [ null, i ];

		i += l[1];

		if (l[0] == 0)
			return [ words, i ];

		if (i + l[0] > length(buf))
			return null;

		push(words, substr(buf, i, l[0]));
		i += l[0];
	}
}

/* ---------- requests ---------- */

// words -> { command, attrs, queries, tag }
function parse_request(words) {
	let r = { command: words[0] ?? '', attrs: {}, queries: [], tag: null };

	for (let w in slice(words, 1)) {
		if (substr(w, 0, 1) == '=') {
			let i = index(substr(w, 1), '=');
			if (i < 0)
				r.attrs[substr(w, 1)] = '';
			else
				r.attrs[substr(w, 1, i)] = substr(w, i + 2);
		}
		else if (substr(w, 0, 5) == '.tag=') {
			r.tag = substr(w, 5);
		}
		else if (substr(w, 0, 1) == '?') {
			push(r.queries, substr(w, 1));
		}
	}

	return r;
}

// RouterOS query words on a list of { key: value } items: "k=v", "k" (has),
// "-k" (has not), ">k=v", "<k=v", and the stack operations "#|", "#&", "#!".
// Without operations all conditions must hold.
function query_match(item, queries) {
	let stack = [];

	for (let q in queries) {
		if (substr(q, 0, 1) == '#') {
			for (let op in split(substr(q, 1), '')) {
				if (op == '!') {
					push(stack, !pop(stack));
				}
				else if (op == '|' || op == '&') {
					let b = pop(stack), a = pop(stack);
					push(stack, (op == '|') ? (a || b) : (a && b));
				}
			}
			continue;
		}

		// "?=k=v" (explicit operator, as librouteros writes it) equals "?k=v".
		let op = substr(q, 0, 1);
		if (op == '-' || op == '>' || op == '<' || op == '=')
			q = substr(q, 1);
		else
			op = '=';

		let i = index(q, '=');
		let k = (i < 0) ? q : substr(q, 0, i), v = (i < 0) ? null : substr(q, i + 1);
		let have = exists(item, k);

		if (op == '-')
			push(stack, !have);
		else if (v == null)
			push(stack, have);
		else if (op == '>')
			push(stack, have && +item[k] > +v);
		else if (op == '<')
			push(stack, have && +item[k] < +v);
		else
			push(stack, have && `${item[k]}` == v);
	}

	for (let x in stack)
		if (!x)
			return false;

	return true;
}

/* ---------- RouterOS formatting ---------- */

function ros_dur(s) {
	s = int(s ?? 0);

	if (s <= 0)
		return '0s';

	let out = '';

	for (let u in [ [ 'w', 604800 ], [ 'd', 86400 ], [ 'h', 3600 ], [ 'm', 60 ], [ 's', 1 ] ]) {
		if (s >= u[1]) {
			out += int(s / u[1]) + u[0];
			s %= u[1];
		}
	}

	return out;
}

function ros_mac(m) {
	return uc(m ?? '');
}

function ros_bool(b) {
	return b ? 'true' : 'false';
}

function ros_id(n) {
	return sprintf('*%X', n);
}

function id_num(id) {
	if (substr(id ?? '', 0, 1) != '*')
		return null;

	let n = hex(substr(id, 1));
	return (type(n) == 'int') ? n : null;
}

function read_kv(path) {
	let out = {};

	for (let l in split(fs.readfile(path) ?? '', '\n')) {
		let m = match(l, /^([A-Za-z_]+)='?([^']*)'?$/);
		if (m)
			out[m[1]] = m[2];
	}

	return out;
}

function meminfo() {
	let out = {};

	for (let l in split(fs.readfile('/proc/meminfo') ?? '', '\n')) {
		let m = match(l, /^([A-Za-z]+):[[:space:]]+([0-9]+)/);
		if (m)
			out[m[1]] = int(m[2]);
	}

	return out;
}

/* ---------- server ---------- */

// opts: { core, port, version }
function server(opts) {
	let core = opts.core;
	let cfg = () => core.config();
	let conns = {};
	let user_ids = {}, next_user_id = 1;	// RouterOS-style ids for local users
	let mac_ids = {}, next_mac_id = 1;	// stable ids for hosts and cookies (by MAC)
	let failed = {};			// address -> { n, at }: failed logins
	let rates = {};				// session id -> { t, in, out, rin, rout }

	let lsock = socket.create(socket.AF_INET6, socket.SOCK_STREAM | socket.SOCK_NONBLOCK);

	if (!lsock) {
		log('error', 'API: cannot create socket: %s', socket.error());
		return null;
	}

	lsock.setopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, false);
	lsock.setopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, true);

	// Object address: OpenWrt 24.10's socket module cannot parse "[::]:port".
	if (!lsock.bind({ family: socket.AF_INET6, address: '::', port: +opts.port }) || !lsock.listen(8)) {
		log('error', 'API: cannot listen on port %d: %s', opts.port, socket.error());
		lsock.close();
		return null;
	}

	/* --- who may connect and log in --- */

	function allowed(addr) {
		let list = cfg().global.api_allow;

		if (!length(list)) {
			// Default: the RADIUS servers (where billing systems live) and localhost.
			list = [ '127.0.0.1', '::1', ...map(cfg().radius, (r) => r.address) ];
		}

		for (let a in list) {
			let p = split(a, '/');
			let net = iptoarr(p[0]), ip = iptoarr(addr);

			if (!net || !ip || length(net) != length(ip))
				continue;

			// A malformed prefix length ("10.0.0.0/", "/abc") must not match
			// everything: skip the entry.
			let bits = length(net) * 8;
			if (p[1] != null) {
				if (!match(p[1], /^[0-9]{1,3}$/) || int(p[1]) > bits)
					continue;
				bits = int(p[1]);
			}

			let ok = true;

			for (let i = 0; i < length(net) && bits > 0; i++, bits -= 8) {
				let mask = (bits >= 8) ? 0xff : (0xff << (8 - bits)) & 0xff;
				if ((net[i] & mask) != (ip[i] & mask))
					ok = false;
			}

			if (ok)
				return true;
		}

		return false;
	}

	function login_ok(name, password) {
		let g = cfg().global;

		if (length(g.api_user) && name == g.api_user && length(g.api_password) && password == g.api_password)
			return true;

		return operator_verify(name, password) == 'admin';
	}

	function login_challenge_ok(name, response, challenge) {
		let g = cfg().global;

		if (!length(g.api_user) || name != g.api_user || !length(g.api_password))
			return false;

		return response == '00' + md5(chr(0) + g.api_password + challenge);
	}

	/* --- data views (RouterOS property names) --- */

	function sessions() {
		let now = time();
		let out = [];

		for (let s in core.sessions()) {
			// Current rate from the bytes seen between two API reads.
			let r = rates[s.id];
			let rin = 0, rout = 0;

			if (r && now > r.t) {
				rin = int((s.bytes_in - r.in) * 8 / (now - r.t));
				rout = int((s.bytes_out - r.out) * 8 / (now - r.t));
			}
			else if (r) {
				rin = r.rin;
				rout = r.rout;
			}

			if (!r || now > r.t)
				rates[s.id] = { t: now, in: s.bytes_in, out: s.bytes_out, rin, rout };

			push(out, { ...s, rate_in: max(0, rin), rate_out: max(0, rout) });
		}

		let live = {};
		for (let s in out)
			live[s.id] = true;
		for (let id in keys(rates))
			if (!live[id])
				delete rates[id];

		return out;
	}

	function active_items() {
		return map(sessions(), (s) => ({
			'.id': ros_id(s.slot),
			server: s.server, user: s.user, domain: '',
			address: s.ipv4[0] ?? '', 'mac-address': ros_mac(s.mac),
			'login-by': s.login_by, uptime: ros_dur(s.uptime), 'idle-time': ros_dur(s.idle_time),
			...(s.session_time_left != null ? { 'session-time-left': ros_dur(s.session_time_left) } : {}),
			'bytes-in': `${s.bytes_in}`, 'bytes-out': `${s.bytes_out}`,
			'packets-in': `${s.packets_in ?? 0}`, 'packets-out': `${s.packets_out ?? 0}`,
			radius: ros_bool(s.auth == 'radius'), blocked: 'false',
			'ipv6-addresses': join(',', s.ipv6),
		}));
	}

	// Ids stay with the device: a list position would point at another
	// client once a host comes or goes between a print and a remove.
	function mac_id(key) {
		mac_ids[key] ??= next_mac_id++;
		return ros_id(mac_ids[key]);
	}

	function host_items() {
		return map(core.hosts(), (h) => ({
			'.id': mac_id(`h ${h.mac}`),
			'mac-address': ros_mac(h.mac), address: sort(keys(h.ip4 ?? {}))[0] ?? (h.ipv4?.[0] ?? ''),
			'to-address': sort(keys(h.ip4 ?? {}))[0] ?? (h.ipv4?.[0] ?? ''),
			server: h.server ?? '', authorized: ros_bool(h.authorized), bypassed: 'false',
			'found-by': 'neighbor', comment: '',
		}));
	}

	function user_id(name) {
		user_ids[name] ??= next_user_id++;
		return ros_id(user_ids[name]);
	}

	function user_by_ref(ref) {
		let n = id_num(ref);

		for (let u in core.users().list())
			if ((n != null && user_ids[u.name] == n) || u.name == ref)
				return u;

		return null;
	}

	function user_items() {
		return map(core.users().list(), (u) => ({
			'.id': user_id(u.name), name: u.name, password: u.password ?? '',
			profile: u.profile ?? 'default', server: length(u.server) ? u.server : 'all',
			'mac-address': ros_mac(u.mac), email: u.email ?? '',
			'limit-uptime': ros_dur(u.limit_uptime), 'limit-bytes-in': `${u.limit_bytes_in ?? 0}`,
			'limit-bytes-out': `${u.limit_bytes_out ?? 0}`, 'limit-bytes-total': `${u.limit_bytes_total ?? 0}`,
			uptime: ros_dur(u.used?.uptime), 'bytes-in': `${u.used?.bytes_in ?? 0}`, 'bytes-out': `${u.used?.bytes_out ?? 0}`,
			disabled: ros_bool(u.disabled), comment: u.comment ?? '', dynamic: 'false',
		}));
	}

	function parse_ros_dur(v) {
		if (v == null || v == '')
			return null;

		let total = 0, re = /([0-9]+)([wdhms])/g;
		let mult = { w: 604800, d: 86400, h: 3600, m: 60, s: 1 };

		if (match(v, /^[0-9]+$/))
			return int(v);

		for (let m in match(v, re))
			total += int(m[1]) * mult[m[2]];

		return total;
	}

	// RouterOS user attributes -> our user fields.
	function user_attrs(a) {
		let u = {};

		if (exists(a, 'password')) u.password = a.password;
		if (exists(a, 'profile')) u.profile = a.profile;
		if (exists(a, 'server')) u.server = (a.server == 'all') ? '' : a.server;
		if (exists(a, 'mac-address')) u.mac = lc(a['mac-address']);
		if (exists(a, 'email')) u.email = a.email;
		if (exists(a, 'comment')) u.comment = a.comment;
		if (exists(a, 'disabled')) u.disabled = (a.disabled == 'yes' || a.disabled == 'true');
		if (exists(a, 'limit-uptime')) u.limit_uptime = `${parse_ros_dur(a['limit-uptime']) ?? 0}`;

		for (let k in [ 'limit-bytes-in', 'limit-bytes-out', 'limit-bytes-total' ])
			if (exists(a, k))
				u[replace(k, /-/g, '_')] = a[k];

		return u;
	}

	function profile_items() {
		let i = 0;

		return map(sort(keys(cfg().user_profiles)), (n) => {
			let p = cfg().user_profiles[n];

			return {
				'.id': ros_id(++i), name: n, 'rate-limit': p.rate_limit ?? '',
				'shared-users': p.shared_users ? `${p.shared_users}` : 'unlimited',
				'session-timeout': ros_dur(p.session_timeout), 'idle-timeout': p.idle_timeout ? ros_dur(p.idle_timeout) : 'none',
				'keepalive-timeout': ros_dur(p.keepalive_timeout), 'status-autorefresh': ros_dur(p.status_autorefresh),
				'add-mac-cookie': ros_bool(p.add_mac_cookie), 'mac-cookie-timeout': ros_dur(p.mac_cookie_timeout),
			};
		});
	}

	function server_items() {
		let i = 0, devs = core.devices();

		return map(sort(keys(cfg().servers)), (n) => {
			let s = cfg().servers[n];
			let dev = null;

			for (let d, srv in devs)
				if (srv == n)
					dev = d;

			return {
				'.id': ros_id(++i), name: n, interface: s.interface ?? dev ?? '', profile: s.profile ?? 'default',
				'address-pool': 'none', 'idle-timeout': ros_dur(s.idle_timeout), 'addresses-per-mac': 'unlimited',
				disabled: 'false', invalid: ros_bool(!dev),
			};
		});
	}

	function cookie_items() {
		let c = core.cookies(), out = [];

		for (let x in c.mac_cookies)
			push(out, { '.id': mac_id(`m ${x.mac}`), user: x.user, 'mac-address': ros_mac(x.mac), 'expires-in': ros_dur(x.expires_in), 'mac-cookie': 'true' });
		for (let x in c.cookies)
			push(out, { '.id': mac_id(`c ${x.mac} ${x.user}`), user: x.user, 'mac-address': ros_mac(x.mac), 'expires-in': ros_dur(x.expires_in), 'mac-cookie': 'false' });

		return out;
	}

	function queue_items() {
		return map(sessions(), (s) => {
			let p = parse_rate_limit(s.rate_limit);
			let ml = p ? `${p.rx.rate}/${p.tx.rate}` : '0/0';

			return {
				'.id': ros_id(0x1000 + s.slot), name: `<hotspot-${s.user}>`,
				target: s.ipv4[0] ? `${s.ipv4[0]}/32` : '', 'max-limit': ml, 'limit-at': '0/0',
				priority: p ? `${p.rx.priority}/${p.tx.priority}` : '8/8',
				bytes: `${s.bytes_in}/${s.bytes_out}`, packets: `${s.packets_in ?? 0}/${s.packets_out ?? 0}`,
				rate: `${s.rate_in}/${s.rate_out}`, dynamic: 'true', disabled: 'false', comment: '',
			};
		});
	}

	function interface_items() {
		let i = 0;

		return map(filter(sort(fs.lsdir('/sys/class/net') ?? []), (d) => d != 'lo'), (d) => {
			let base = `/sys/class/net/${d}`;
			let rd = (f) => trim(fs.readfile(`${base}/${f}`) ?? '');
			let kind = fs.access(`${base}/bridge`) ? 'bridge' : fs.access(`${base}/wireless`) || fs.access(`${base}/phy80211`) ? 'wlan'
				: match(d, /\./) ? 'vlan' : 'ether';

			return {
				'.id': ros_id(++i), name: d, type: kind, mtu: rd('mtu'), 'actual-mtu': rd('mtu'),
				'mac-address': ros_mac(rd('address')), running: ros_bool(rd('operstate') == 'up' || rd('carrier') == '1'),
				disabled: 'false',
			};
		});
	}

	function address_items() {
		let i = 0, out = [];

		for (let a in rtnl.request(rtnl.const.RTM_GETADDR, rtnl.const.NLM_F_DUMP, {}) ?? []) {
			if (a.family != 2 || !a.address)
				continue;

			let p = split(a.address, '/');
			let bits = int(p[1] ?? 32), ip = iptoarr(p[0]);
			let net = map(ip, (b, k) => { let left = bits - k * 8; return (left >= 8) ? b : (left <= 0) ? 0 : b & ((0xff << (8 - left)) & 0xff); });

			push(out, { '.id': ros_id(++i), address: a.address, network: arrtoip(net), interface: a.dev, disabled: 'false', dynamic: 'false' });
		}

		return out;
	}

	function resource_item() {
		let mi = meminfo();
		let rel = read_kv('/etc/openwrt_release');
		let up = int(split(fs.readfile('/proc/uptime') ?? '0', ' ')[0]);
		let ncpu = length(filter(split(fs.readfile('/proc/cpuinfo') ?? '', '\n'), (l) => match(l, /^processor/))) || 1;
		let load = +(split(fs.readfile('/proc/loadavg') ?? '0', ' ')[0]);
		let df = fs.popen('df -k /overlay 2>/dev/null || df -k / 2>/dev/null', 'r');
		let dfl = split(trim(df?.read('all') ?? ''), '\n');
		df?.close();
		let f = split(trim(dfl[-1] ?? ''), /[[:space:]]+/);

		return {
			uptime: ros_dur(up), version: opts.version, 'build-time': '', 'factory-software': '',
			'free-memory': `${(mi.MemAvailable ?? 0) * 1024}`, 'total-memory': `${(mi.MemTotal ?? 0) * 1024}`,
			cpu: rel.DISTRIB_ARCH ?? '', 'cpu-count': `${ncpu}`, 'cpu-frequency': '0',
			'cpu-load': `${min(100, int(load * 100 / ncpu))}`,
			'free-hdd-space': `${int(f[3] ?? 0) * 1024}`, 'total-hdd-space': `${int(f[1] ?? 0) * 1024}`,
			'architecture-name': rel.DISTRIB_ARCH ?? '', 'board-name': trim(fs.readfile('/tmp/sysinfo/model') ?? 'OpenWrt'),
			platform: 'WrtHotspot',
		};
	}

	/* --- commands --- */

	function trap(msg, category) {
		return { trap: msg, category };
	}

	function localtime_str(fmt) {
		let t = localtime();
		return replace(replace(replace(replace(replace(replace(fmt,
			'%Y', sprintf('%04d', t.year)), '%m', sprintf('%02d', t.mon)), '%d', sprintf('%02d', t.mday)),
			'%H', sprintf('%02d', t.hour)), '%M', sprintf('%02d', t.min)), '%S', sprintf('%02d', t.sec));
	}

	// List commands: menu -> item producer.
	const LISTS = {
		'/ip/hotspot/active': active_items,
		'/ip/hotspot/host': host_items,
		'/ip/hotspot/user': user_items,
		'/ip/hotspot/user/profile': profile_items,
		'/ip/hotspot': server_items,
		'/ip/hotspot/cookie': cookie_items,
		'/queue/simple': queue_items,
		'/interface': interface_items,
		'/ip/address': address_items,
		'/system/resource': () => [ resource_item() ],
		'/system/identity': () => [ { name: trim(fs.readfile('/proc/sys/kernel/hostname') ?? 'OpenWrt') } ],
		'/system/clock': () => [ { time: localtime_str('%H:%M:%S'), date: localtime_str('%Y-%m-%d'), 'time-zone-name': trim(fs.readfile('/etc/TZ') ?? 'UTC') } ],
		'/system/routerboard': () => [ { routerboard: 'false' } ],
		'/radius': () => map(cfg().radius, (r, i) => ({ '.id': ros_id(i + 1), service: 'hotspot', address: r.address,
			'authentication-port': `${r.auth_port}`, 'accounting-port': `${r.acct_port}`, timeout: `${r.timeout}ms`, disabled: 'false' })),
		'/radius/incoming': () => [ { accept: ros_bool(cfg().global.coa_port > 0), port: `${cfg().global.coa_port}` } ],
		// Menus that billing systems poll for other services: always empty here.
		'/ppp/active': () => [],
		'/ppp/secret': () => [],
		'/interface/pppoe-server': () => [],
		'/interface/pppoe-server/server': () => [],
	};

	function refs(a) {
		return filter(split(a['.id'] ?? a.numbers ?? '', ','), (x) => length(x));
	}

	function do_print(menu, req) {
		let items = filter(LISTS[menu](), (it) => query_match(it, req.queries));

		if (exists(req.attrs, 'count-only'))
			return { done: { ret: `${length(items)}` } };

		let props = req.attrs['.proplist'];
		if (props != null) {
			let want = split(props, ',');
			items = map(items, (it) => {
				let o = {};
				for (let k in want)
					if (exists(it, k))
						o[k] = it[k];
				return o;
			});
		}

		return { items };
	}

	function do_remove(menu, req) {
		let r = refs(req.attrs);

		if (!length(r))
			return trap('no such item', 0);

		if (menu == '/ip/hotspot/active') {
			for (let id in r) {
				let slot = id_num(id);
				if (slot == null || !core.logout(slot, 'admin-reset'))
					return trap('no such item', 0);
			}
			return {};
		}

		if (menu == '/ip/hotspot/user') {
			for (let id in r) {
				let u = user_by_ref(id);
				if (!u)
					return trap('no such item', 0);

				core.users().remove(u.name);
				core.logout_where({ user: u.name }, 'user-removed');
				delete user_ids[u.name];
			}
			return {};
		}

		if (menu == '/ip/hotspot/host' || menu == '/ip/hotspot/cookie') {
			let items = LISTS[menu]();
			for (let id in r) {
				// by id, or by MAC address as RouterOS also accepts
				let it = filter(items, (x) => x['.id'] == id || x['mac-address'] == uc(id))[0];
				if (!it)
					return trap('no such item', 0);

				if (menu == '/ip/hotspot/cookie')
					core.cookie_remove({ mac: lc(it['mac-address']) });
				else
					core.logout_where({ mac: lc(it['mac-address']) }, 'admin-reset');
			}
			return {};
		}

		return trap('no such command', 0);
	}

	function do_user_add(req) {
		let a = req.attrs;

		if (!length(a.name))
			return trap('failure: name is required', 1);

		if (core.users().get(a.name))
			return trap('failure: already have user with this name', 1);

		let c = core.check_users(1, false, 'api');
		if (!c[0])
			return trap(`failure: ${c[1]}`, 1);

		let res = core.users().set(a.name, { password: '', profile: 'default', ...user_attrs(a) });
		if (!res[0])
			return trap(`failure: ${res[1]}`, 1);

		return { done: { ret: user_id(a.name) } };
	}

	function do_user_set(req) {
		let r = refs(req.attrs);

		if (!length(r))
			return trap('no such item', 0);

		for (let id in r) {
			let u = user_by_ref(id);
			if (!u)
				return trap('no such item', 0);

			let res = core.users().set(u.name, user_attrs(req.attrs));
			if (!res[0])
				return trap(`failure: ${res[1]}`, 1);
		}

		return {};
	}

	function dispatch(req) {
		let cmd = req.command;
		let i = rindex(cmd, '/');
		let menu = substr(cmd, 0, i), verb = substr(cmd, i + 1);

		if (cmd == '/cancel')
			return {};

		if (verb == 'print' || verb == 'getall') {
			if (!LISTS[menu])
				return trap('no such command prefix', 0);

			return do_print(menu, req);
		}

		if (verb == 'remove')
			return do_remove(menu, req);

		if (menu == '/ip/hotspot/user' && verb == 'add')
			return do_user_add(req);

		if (menu == '/ip/hotspot/user' && verb == 'set')
			return do_user_set(req);

		return trap(LISTS[menu] ? 'no such command' : 'no such command prefix', 0);
	}

	/* --- connections --- */

	function send_words(c, words) {
		c.out += sentence(words);
	}

	function reply(c, req, res) {
		let tag = (req.tag != null) ? [ `.tag=${req.tag}` ] : [];

		for (let it in res.items ?? []) {
			let w = [ '!re' ];
			for (let k, v in it)
				push(w, `=${k}=${v ?? ''}`);
			send_words(c, [ ...w, ...tag ]);
		}

		if (res.trap != null) {
			send_words(c, [ '!trap', `=message=${res.trap}`, ...(res.category != null ? [ `=category=${res.category}` ] : []), ...tag ]);
			send_words(c, [ '!done', ...tag ]);
			return;
		}

		let d = [ '!done' ];
		for (let k, v in res.done ?? {})
			push(d, `=${k}=${v}`);
		send_words(c, [ ...d, ...tag ]);
	}

	let accept_handle;
	let on_event;		// assigned below; flush() re-registers it

	function close_conn(c) {
		if (!conns[c.fd])
			return;

		c.h?.delete();
		c.sock.close();
		delete conns[c.fd];
	}

	function flush(c) {
		while (length(c.out)) {
			let n = c.sock.send(c.out);

			if (n == null || n <= 0)
				break;

			c.out = substr(c.out, n);
		}

		let want_write = length(c.out) > 0;

		if (want_write != c.writing) {
			c.writing = want_write;
			c.h.delete();
			c.h = uloop.handle(c.fd, (ev) => on_event(c, ev), uloop.ULOOP_READ | (want_write ? uloop.ULOOP_WRITE : 0));
		}

		if (!want_write && c.closing)
			close_conn(c);
	}

	function handle_login(c, req) {
		let a = req.attrs;

		if (exists(a, 'response')) {
			if (c.challenge && login_challenge_ok(a.name, a.response, c.challenge)) {
				c.user = a.name;
				return {};
			}
		}
		else if (exists(a, 'name') && exists(a, 'password')) {
			if (login_ok(a.name, a.password)) {
				c.user = a.name;
				return {};
			}
		}
		else {
			c.challenge = random_bytes(16);
			let hexch = '';
			for (let i = 0; i < 16; i++)
				hexch += sprintf('%02x', ord(c.challenge, i));
			return { done: { ret: hexch } };
		}

		log('warn', 'API: failed login for "%s" from %s', a.name ?? '', c.peer);
		c.closing = ++c.failures >= 3;

		// Per address: after a few failures in a row, refuse it for a while.
		let f = failed[c.peer] ?? { n: 0, at: 0 };
		f = (time() - f.at > FAIL_WINDOW) ? { n: 1, at: time() } : { n: f.n + 1, at: f.at };
		failed[c.peer] = f;

		if (f.n >= FAIL_LIMIT) {
			log('warn', 'API: %d failed logins from %s, refusing it for %d s', f.n, c.peer, FAIL_WINDOW);
			c.closing = true;
		}

		return trap('invalid user name or password (6)', null);
	}

	function on_request(c, words) {
		let req = parse_request(words);

		if (req.command == '/quit') {
			send_words(c, [ '!fatal', 'session terminated on request' ]);
			c.closing = true;
			return;
		}

		if (req.command == '/login') {
			reply(c, req, handle_login(c, req));
			if (c.user)
				log('info', 'API: %s logged in from %s', c.user, c.peer);
			return;
		}

		if (!c.user) {
			send_words(c, [ '!fatal', 'not logged in' ]);
			c.closing = true;
			return;
		}

		reply(c, req, dispatch(req));
	}

	on_event = function(c, ev) {
		if (ev & uloop.ULOOP_READ) {
			let got = false;

			while (true) {
				let data = c.sock.recv(16384);

				// Readable but nothing to read: the connection failed (reset).
				if (data == null && !got) {
					close_conn(c);
					return;
				}

				if (data == null)
					break;

				got = true;

				if (data == '') {
					close_conn(c);
					return;
				}

				c.buf += data;
				c.seen = time();

				if (length(c.buf) > 4 * MAX_SENTENCE) {
					close_conn(c);
					return;
				}
			}

			while (true) {
				let s = next_sentence(c.buf);

				if (s == null)
					break;

				if (s[0] == null) {
					close_conn(c);
					return;
				}

				c.buf = substr(c.buf, s[1]);

				if (length(s[0]))
					on_request(c, s[0]);

				// Failed login, not logged in, /quit: nothing queued behind it may
				// run (pipelined password guesses, commands after a bad login).
				if (c.closing) {
					c.buf = '';
					break;
				}
			}
		}

		flush(c);
	};

	accept_handle = uloop.handle(lsock.fileno(), () => {
		while (true) {
			let cs = lsock.accept(null, socket.SOCK_NONBLOCK);

			if (!cs)
				break;

			let pn = cs.peername() ?? {};
			let addr = pn.address ?? '';
			if (substr(addr, 0, 7) == '::ffff:')
				addr = substr(addr, 7);

			let fl = failed[addr];
			let blocked = fl && fl.n >= FAIL_LIMIT && time() - fl.at <= FAIL_WINDOW;

			if (!allowed(addr) || blocked || length(keys(conns)) >= MAX_CONN) {
				log('warn', 'API: connection from %s refused (%s)', addr,
					!allowed(addr) ? 'not in api_allow' : blocked ? 'too many failed logins' : 'too many connections');
				cs.close();
				continue;
			}

			cs.setopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, true);

			let c = { sock: cs, fd: cs.fileno(), peer: addr, buf: '', out: '', user: null, challenge: null,
				failures: 0, writing: false, closing: false, seen: time() };

			c.h = uloop.handle(c.fd, (ev) => on_event(c, ev), uloop.ULOOP_READ);
			conns[c.fd] = c;
		}
	}, uloop.ULOOP_READ);

	// Idle connections are closed.
	let idle_timer;
	idle_timer = uloop.timer(30000, () => {
		let now = time();
		for (let fd, c in conns)
			if (now - c.seen > IDLE_CLOSE)
				close_conn(c);

		for (let a, f in failed)
			if (now - f.at > FAIL_WINDOW)
				delete failed[a];

		// Random MACs would grow the id map forever; starting over only
		// renumbers (billing systems print before they remove).
		if (length(keys(mac_ids)) > 20000)
			mac_ids = {};

		idle_timer.set(30000);
	});

	log('info', 'RouterOS API listening on tcp/%d', opts.port);

	return {
		port: opts.port,
		connections: () => length(keys(conns)),
		close: function() {
			for (let fd, c in conns)
				close_conn(c);
			idle_timer.cancel();
			accept_handle.delete();
			lsock.close();
		},
	};
};

// Loaded with require() by the core.
return { server, sentence, next_sentence: next_sentence, parse_request, query_match };
