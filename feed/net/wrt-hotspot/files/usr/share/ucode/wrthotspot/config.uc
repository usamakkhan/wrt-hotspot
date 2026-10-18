// UCI /etc/config/wrthotspot -> normalized objects.
'use strict';

import { cursor } from 'uci';
import { parse_duration, parse_size, to_bool, as_list, normalize_mac, log } from 'wrthotspot.util';
import { parse_rate_limit, parse_rate } from 'wrthotspot.shaper';
import * as limits from 'wrthotspot.limits';

const LOGIN_METHODS = [ 'mac', 'cookie', 'http-chap', 'http-pap', 'https', 'trial', 'mac-cookie' ];

function dur(v, dflt) {
	let d = parse_duration(v ?? dflt);
	return (d == null) ? parse_duration(dflt) : d;
}

function server_profile(s) {
	let login_by = filter(as_list(s.login_by ?? [ 'http-chap', 'cookie' ]), (m) => (m in LOGIN_METHODS));

	return {
		name: s.name ?? s['.name'],
		dns_name: s.dns_name ?? '',
		html_directory: s.html_directory ?? '/usr/share/wrthotspot/pages/default',
		login_by,
		http_cookie_lifetime: dur(s.http_cookie_lifetime, '3d'),
		mac_auth_password: s.mac_auth_password ?? '',
		trial_uptime_limit: dur(s.trial_uptime_limit, '30m'),
		trial_uptime_reset: dur(s.trial_uptime_reset, '1d'),
		trial_user_profile: s.trial_user_profile ?? 'default',
		split_user_domain: to_bool(s.split_user_domain),
		rfc8910: to_bool(s.rfc8910 ?? '1'),
		use_radius: to_bool(s.use_radius),
		radius_accounting: to_bool(s.radius_accounting ?? '1'),
		// "received" = use Acct-Interim-Interval from the server, else a duration.
		radius_interim_update: (s.radius_interim_update == null || s.radius_interim_update == 'received')
			? 'received' : dur(s.radius_interim_update, '0'),
		radius_mac_format: s.radius_mac_format ?? 'XX:XX:XX:XX:XX:XX',
		nas_port_type: s.nas_port_type ?? 'wireless-802.11',
		radius_location_id: s.radius_location_id ?? '',
		radius_location_name: s.radius_location_name ?? '',
	};
}

function radius_server(s) {
	let t = match(`${s.timeout ?? '1100'}`, /^(\d+)(ms|s)?$/);

	return {
		name: s['.name'],
		address: s.address,
		secret: s.secret ?? '',
		auth_port: int(s.auth_port ?? 1812),
		acct_port: int(s.acct_port ?? 1813),
		timeout: t ? ((t[2] == 's') ? int(t[1]) * 1000 : int(t[1])) : 1100,
		retries: int(s.retries ?? 2),
		// Responses must carry a Message-Authenticator (BlastRADIUS,
		// CVE-2024-3596). Turn off only for servers that can't send one.
		require_message_auth: to_bool(s.require_message_auth ?? '1'),
	};
}

function user_profile(s) {
	return {
		name: s.name ?? s['.name'],
		shared_users: (s.shared_users == 'unlimited') ? 0 : int(s.shared_users ?? 1),
		session_timeout: dur(s.session_timeout, '0'),
		idle_timeout: dur(s.idle_timeout, '0'),
		keepalive_timeout: dur(s.keepalive_timeout, '2m'),
		status_autorefresh: dur(s.status_autorefresh, '1m'),
		rate_limit: s.rate_limit ?? '',
		add_mac_cookie: to_bool(s.add_mac_cookie ?? '1'),
		mac_cookie_timeout: dur(s.mac_cookie_timeout, '3d'),
		on_login: s.on_login ?? '',
		on_logout: s.on_logout ?? '',
		limitations: as_list(s.limitation),
	};
}

function server(s) {
	return {
		name: s.name ?? s['.name'],
		enabled: to_bool(s.enabled ?? '1'),
		interface: s.interface,		// OpenWrt logical network, resolved to its L3 device
		device: s.device,		// or an explicit device name
		profile: s.profile ?? 'default',
		idle_timeout: dur(s.idle_timeout, '5m'),		// unauthorized hosts
		keepalive_timeout: dur(s.keepalive_timeout, '0'),
		login_timeout: dur(s.login_timeout, '0'),
	};
}

// "1.2.3.4", "10.0.0.0/8", "2001:db8::/32" -> { family, cidr } or null.
export function parse_prefix(v) {
	let m = match(trim(`${v ?? ''}`), /^([^\/]+)(\/(\d+))?$/);
	let a = m ? iptoarr(m[1]) : null;

	if (!a)
		return null;

	let family = (length(a) == 16) ? 6 : 4;
	let bits = (m[3] != null) ? int(m[3]) : ((family == 6) ? 128 : 32);

	if (bits < 0 || bits > ((family == 6) ? 128 : 32))
		return null;

	// Clear host bits so "10.0.0.5/8" becomes "10.0.0.0/8".
	for (let i = 0; i < length(a); i++) {
		let keep = min(8, max(0, bits - i * 8));
		a[i] &= (0xff << (8 - keep)) & 0xff;
	}

	return { family, cidr: (m[3] != null) ? `${arrtoip(a)}/${bits}` : arrtoip(a) };
};

// Domain for dnsmasq/nslookup: "*.example.com" and "example.com" both mean
// the domain and its subdomains (dnsmasq semantics).
export function parse_host(v) {
	let h = lc(trim(`${v ?? ''}`));

	if (substr(h, 0, 2) == '*.')
		h = substr(h, 2);

	return match(h, /^([a-z0-9_]([a-z0-9_-]*[a-z0-9_])?\.)*[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?\.?$/) ? rtrim(h, '.') : null;
};

function walled_garden(s, idx) {
	let e = {
		idx,
		action: (s.action == 'deny') ? 'deny' : 'allow',
		server: s.server ?? 'all',
		host: null, prefixes: [],
		protocol: (s.protocol in [ 'tcp', 'udp' ]) ? s.protocol : null,
		dst_port: null,
		comment: s.comment ?? '',
	};

	if (s.dst_host) {
		e.host = parse_host(s.dst_host);

		if (!e.host)
			return [ null, `invalid dst_host "${s.dst_host}"` ];
	}

	for (let a in as_list(s.dst_address)) {
		let p = parse_prefix(a);

		if (!p)
			return [ null, `invalid dst_address "${a}"` ];

		push(e.prefixes, p);
	}

	if (s.dst_port != null && s.dst_port !== '') {
		if (!match(`${s.dst_port}`, /^\d{1,5}(-\d{1,5})?$/))
			return [ null, `invalid dst_port "${s.dst_port}"` ];

		e.dst_port = `${s.dst_port}`;
		e.protocol ??= 'tcp';
	}

	if (!e.host && !length(e.prefixes) && !e.dst_port)
		return [ null, 'needs dst_host, dst_address or dst_port' ];

	return [ e, null ];
}

function ip_binding(s) {
	let b = {
		type: (s.type in [ 'bypassed', 'blocked', 'regular' ]) ? s.type : 'regular',
		server: s.server ?? 'all',
		mac: (s.mac != null && s.mac !== '') ? normalize_mac(s.mac) : null,
		address: null,
		comment: s.comment ?? '',
	};

	if (s.mac != null && s.mac !== '' && !b.mac)
		return [ null, `invalid mac "${s.mac}"` ];

	if (s.address != null && s.address !== '') {
		b.address = parse_prefix(s.address);

		if (!b.address)
			return [ null, `invalid address "${s.address}"` ];

		// MAC + address is matched as a pair, which needs a single address.
		if (b.mac && index(b.address.cidr, '/') >= 0)
			return [ null, 'mac + address bindings need a single address, not a prefix' ];
	}

	if (!b.mac && !b.address)
		return [ null, 'needs mac or address' ];

	return [ b, null ];
}

export function load(confdir) {
	let c = cursor(confdir);
	let g = c.get_all('wrthotspot', 'global') ?? {};

	let cfg = {
		global: {
			enabled: to_bool(g.enabled ?? '1'),
			poll_interval: dur(g.poll_interval, '10s') || 10,
			portal_port: int(g.portal_port ?? 8002),
			state_dir: g.state_dir ?? '/tmp/wrthotspot',
			db_dir: g.db_dir ?? '/etc/wrthotspot',
			db_sync_interval: dur(g.db_sync_interval, '5m') || 300,
			log_level: g.log_level ?? 'info',
			nas_identifier: g.nas_identifier ?? '',
			https_port: int(g.https_port ?? (int(g.portal_port ?? 8002) + 1)),
			ssl_certificate: g.ssl_certificate ?? '',
			ssl_key: g.ssl_key ?? '',
			resolve_interval: dur(g.resolve_interval, '5m') || 300,
			walled_garden_ttl: dur(g.walled_garden_ttl, '1h') || 3600,
			// RFC 5176 CoA / Disconnect-Request listener; 0 disables it.
			coa_port: int(g.coa_port ?? 3799),
			// Rate limiting: auto (tc if available, else nft), tc, nft or off.
			shaper: g.shaper ?? 'auto',
			// Root class rate of the tc trees; keep above the real link speed.
			shaper_capacity: parse_rate(g.shaper_capacity ?? '10G') || 10000000000,
		},
		servers: {},
		radius: [],
		limitations: {},
		walled_garden: [],
		ip_bindings: [],
		server_profiles: {},
		user_profiles: {},
	};

	// Profiles are usually anonymous sections with `option name`, because
	// UCI section names must be unique across types and MikroTik calls both
	// the default server profile and the default user profile "default".
	c.foreach('wrthotspot', 'server_profile', (s) => { let p = server_profile(s); cfg.server_profiles[p.name] = p; });
	c.foreach('wrthotspot', 'user_profile', (s) => { let p = user_profile(s); cfg.user_profiles[p.name] = p; });
	c.foreach('wrthotspot', 'server', (s) => {
		let srv = server(s);

		if (!srv.interface && !srv.device) {
			log('warn', 'Server %s has neither interface nor device, ignoring', srv.name);
			return;
		}

		cfg.servers[srv.name] = srv;
	});

	c.foreach('wrthotspot', 'limitation', (s) => {
		let r = limits.parse(s, parse_duration, parse_size);

		if (r[0] && r[0].rate_limit != '' && !parse_rate_limit(r[0].rate_limit))
			r = [ null, `invalid rate_limit "${r[0].rate_limit}"` ];

		if (r[0])
			cfg.limitations[r[0].name] = r[0];
		else
			log('warn', 'Limitation %s ignored: %s', s['.name'], r[1]);
	});

	for (let name, up in cfg.user_profiles) {
		if (up.rate_limit != '' && !parse_rate_limit(up.rate_limit)) {
			log('warn', 'User profile %s: invalid rate_limit "%s" ignored', name, up.rate_limit);
			up.rate_limit = '';
		}

		up.limitations = filter(up.limitations, (l) => {
			if (cfg.limitations[l])
				return true;

			log('warn', 'User profile %s: unknown limitation %s ignored', name, l);
			return false;
		});
	}

	c.foreach('wrthotspot', 'radius', (s) => {
		if (!to_bool(s.enabled ?? '1'))
			return;

		let r = radius_server(s);

		if (!r.address || !iptoarr(r.address) || r.secret == '')
			log('warn', 'RADIUS server %s ignored: needs an IP address and a secret', s['.name']);
		else
			push(cfg.radius, r);
	});

	let wg_idx = 0;
	c.foreach('wrthotspot', 'walled_garden', (s) => {
		if (!to_bool(s.enabled ?? '1'))
			return;

		let r = walled_garden(s, ++wg_idx);
		if (r[0])
			push(cfg.walled_garden, r[0]);
		else
			log('warn', 'Walled garden entry %s ignored: %s', s['.name'], r[1]);
	});

	c.foreach('wrthotspot', 'ip_binding', (s) => {
		if (!to_bool(s.enabled ?? '1'))
			return;

		let r = ip_binding(s);
		if (r[0])
			push(cfg.ip_bindings, r[0]);
		else
			log('warn', 'IP binding %s ignored: %s', s['.name'], r[1]);
	});

	// Always have defaults so a fresh install works.
	cfg.server_profiles.default ??= server_profile({ '.name': 'default' });
	cfg.user_profiles.default ??= user_profile({ '.name': 'default' });

	return cfg;
};
