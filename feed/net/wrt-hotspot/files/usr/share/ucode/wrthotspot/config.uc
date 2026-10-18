// UCI /etc/config/wrthotspot -> normalized objects.
'use strict';

import { cursor } from 'uci';
import { parse_duration, parse_size, to_bool, as_list, log } from 'wrthotspot.util';

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
		use_radius: to_bool(s.use_radius),
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
		},
		servers: {},
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

	// Always have defaults so a fresh install works.
	cfg.server_profiles.default ??= server_profile({ '.name': 'default' });
	cfg.user_profiles.default ??= user_profile({ '.name': 'default' });

	return cfg;
};
