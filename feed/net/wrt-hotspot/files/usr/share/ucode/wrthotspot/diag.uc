// Health checks shared by `wrthotspot check` and the LuCI diagnostics page.
// Each check: { id, level: 'ok' | 'warn' | 'error' | 'info', message, fix? }
// `fix` names an action the GUI can offer (e.g. 'setup:<network>').
'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';
import { run } from 'wrthotspot.util';
import { dnsmasq_has_nftset } from 'wrthotspot.dns';
import { tc_available } from 'wrthotspot.shaper';

function listening(port) {
	let out = run('netstat -ltn 2>/dev/null').out ?? '';
	return !!match(out, regexp(`:${port}[[:space:]]`));
}

function udp_listening(port) {
	let out = run('netstat -lun 2>/dev/null').out ?? '';
	return !!match(out, regexp(`:${port}[[:space:]]`));
}

// cfg: loaded config; state: { running, devices, shaper, radius_backlog } from hotspotd (optional)
export function run_checks(cfg, state) {
	let out = [];
	let add = (id, level, message, fix) => push(out, { id, level, message, fix });
	let c = cursor();

	c.load('firewall');
	c.load('network');
	c.load('dhcp');

	add('daemon', state?.running ? 'ok' : 'error', state?.running ? 'hotspotd is running' : 'hotspotd is not running');

	let off = false;
	c.foreach('firewall', 'defaults', (s) => { off ||= (s.flow_offloading == '1' || s.flow_offloading_hw == '1'); });
	add('offload', off ? 'error' : 'ok',
		off ? 'Flow offloading is on: offloaded traffic bypasses accounting, limits and logout' : 'Flow offloading is off',
		off ? 'disable_offload' : null);

	let nftv = trim(run('nft --version').out ?? '');
	let destroy = run('printf "table inet wrthotspot_probe\\ndestroy table inet wrthotspot_probe\\n" | nft -c -f -').code == 0;
	add('nft', destroy ? 'ok' : 'error', destroy ? nftv : `${nftv}: no "destroy" support (needs kernel >= 6.3, nft >= 1.0.8)`);

	let tbl = run('nft list chain inet wrthotspot forward >/dev/null').code == 0;
	add('table', tbl ? 'ok' : 'error', tbl ? 'Dataplane table inet wrthotspot is loaded' : 'Dataplane table inet wrthotspot is missing');

	if (!length(keys(cfg.servers)))
		add('servers', 'warn', 'No hotspot server configured yet (Servers tab or `wrthotspot setup <network>`)');

	for (let name, srv in cfg.servers) {
		let dev = null;

		for (let d, s in state?.devices ?? {})
			if (s == name)
				dev = d;

		add(`server:${name}`, dev ? 'ok' : 'error',
			dev ? `Server ${name}: active on ${dev}` : `Server ${name}: interface ${srv.interface ?? srv.device} has no device (down or missing)`);

		if (!srv.interface)
			continue;

		let zone = null, zone_input = null, fwd = false, portal_rule = false, admin_rule = false, dhcp = false;

		c.foreach('firewall', 'zone', (z) => {
			let nets = (type(z.network) == 'array') ? z.network : split(z.network ?? '', ' ');
			if (srv.interface in nets) {
				zone = z.name;
				zone_input = z.input;
			}
		});
		c.foreach('firewall', 'forwarding', (f) => { if (zone && f.src == zone && f.dest == 'wan') fwd = true; });
		c.foreach('firewall', 'rule', (r) => {
			if (r.src == zone && index(`${r.dest_port ?? ''}`, `${cfg.global.portal_port}`) >= 0)
				portal_rule = true;
			if (r.src == zone && r.name == `Allow-${zone}-Admin` && '80' in split(`${r.dest_port ?? ''}`, ' '))
				admin_rule = true;
		});
		c.foreach('dhcp', 'dhcp', (d) => { if (d.interface == srv.interface && d.ignore != '1') dhcp = true; });

		let ok = zone && fwd && portal_rule;
		add(`firewall:${name}`, ok ? 'ok' : 'error',
			ok ? `Server ${name}: firewall zone ${zone} with portal rule and forwarding to wan`
			   : `Server ${name}: firewall incomplete (zone: ${zone ?? 'none'}, wan forwarding: ${fwd ? 'yes' : 'no'}, portal rule: ${portal_rule ? 'yes' : 'no'})`,
			ok ? null : `setup:${srv.interface}`);

		add(`dhcp:${name}`, dhcp ? 'ok' : 'warn',
			dhcp ? `Server ${name}: DHCP is served on ${srv.interface}` : `Server ${name}: no DHCP on ${srv.interface}; clients need addresses`,
			dhcp ? null : `setup:${srv.interface}`);

		if (fs.access('/www/cgi-bin/luci')) {
			let admin_ok = zone_input == 'ACCEPT' || admin_rule;
			add(`admin:${name}`, admin_ok ? 'ok' : 'warn',
				admin_ok ? `Server ${name}: router settings reachable from the hotspot zone`
				         : `Server ${name}: router settings link needs an input rule (rerun wrthotspot setup ${srv.interface})`,
				admin_ok ? null : `setup:${srv.interface}`);
		}

		// Transparent proxy on the router: its port must be open like the portal,
		// and something must listen there.
		let sp = cfg.server_profiles[srv.profile] ?? cfg.server_profiles.default;
		if (sp?.transparent_proxy && sp.http_proxy?.local) {
			let pp = sp.http_proxy.port, open = false;

			c.foreach('firewall', 'rule', (r) => {
				if (r.src == zone && index(split(`${r.dest_port ?? ''}`, ' '), `${pp}`) >= 0)
					open = true;
			});

			add(`proxy:${name}`, (open && listening(pp)) ? 'ok' : 'error',
				!open ? `Server ${name}: transparent proxy port ${pp} is not open for zone ${zone ?? '?'}`
				: !listening(pp) ? `Server ${name}: transparent proxy enabled but nothing listens on port ${pp} (e.g. squid with "http_port ${pp} intercept")`
				: `Server ${name}: transparent HTTP proxy on port ${pp}`,
				open ? null : `setup:${srv.interface}`);
		}
	}

	let portal = listening(cfg.global.portal_port);
	add('portal', portal ? 'ok' : 'error', portal ? `Portal listening on port ${cfg.global.portal_port}` : `Nothing listens on portal port ${cfg.global.portal_port}`);

	let hosts_wg = length(filter(cfg.walled_garden, (e) => e.host));
	let nftset = dnsmasq_has_nftset();
	add('dnsmasq', nftset ? 'ok' : (hosts_wg ? 'warn' : 'info'),
		nftset ? 'dnsmasq supports nftset (walled-garden subdomains)'
		       : 'dnsmasq without nftset: walled-garden hosts work, their subdomains need dnsmasq-full');

	let g = cfg.global;
	if (g.ssl_certificate) {
		let files = fs.stat(g.ssl_certificate) && fs.stat(g.ssl_key);
		let tls = fs.stat('/lib/libustream-ssl.so') || fs.stat('/usr/lib/libustream-ssl.so');
		let https = listening(g.https_port);
		add('https', (files && tls && https) ? 'ok' : 'error',
			!files ? 'Certificate or key file missing' : !tls ? 'No TLS library for uhttpd (install libustream-mbedtls)'
			: !https ? `HTTPS portal not listening on ${g.https_port}` : `HTTPS portal on port ${g.https_port}`);
	}
	else {
		add('https', 'info', 'No certificate: HTTPS login and RFC 8908/8910 announcement are off');
	}

	let has_rates = false;
	for (let n, up in cfg.user_profiles)
		if (up.rate_limit)
			has_rates = true;
	for (let n, l in cfg.limitations)
		if (l.rate_limit)
			has_rates = true;

	let tc = tc_available();
	let backend = state?.shaper ?? 'unknown';
	// Lite mode chooses nft policing on purpose: not worth a warning.
	add('shaper', (backend == 'tc' || state?.lite || (!has_rates && backend != 'unknown')) ? 'ok' : (backend == 'nft' ? 'warn' : 'info'),
		(backend == 'tc') ? 'Rate limits: tc HTB shaping'
		: (backend == 'nft' && state?.lite) ? 'Rate limits: nftables policing (lite mode for a slow router)'
		: (backend == 'nft') ? `Rate limits: nftables policing${tc ? '' : ' (install wrt-hotspot-shaper for HTB shaping)'}`
		: (backend == 'off') ? 'Rate limits are switched off' : 'Rate limiting not active');

	let rad_pkg = fs.access('/usr/share/ucode/wrthotspot/radius.uc');

	if (length(cfg.radius) && !rad_pkg)
		add('radius', 'error', `${length(cfg.radius)} RADIUS server(s) configured but wrt-hotspot-radius is not installed: only local users can log in`);
	else if (length(cfg.radius)) {
		let coa = cfg.global.coa_port ? udp_listening(cfg.global.coa_port) : false;
		add('radius', 'ok', `${length(cfg.radius)} RADIUS server(s) configured`);
		add('coa', !cfg.global.coa_port ? 'info' : (coa ? 'ok' : 'error'),
			!cfg.global.coa_port ? 'CoA/Disconnect listener disabled' : coa ? `CoA/Disconnect listening on udp/${cfg.global.coa_port}` : `CoA port ${cfg.global.coa_port} not listening`);

		if (state?.radius_backlog)
			add('acct_backlog', 'warn', `${state.radius_backlog} accounting request(s) waiting for a RADIUS server`);
	}

	if (cfg.global.api_enable) {
		let g = cfg.global;
		let who = length(g.api_allow) ? join(', ', g.api_allow) : 'the RADIUS servers and localhost';

		if (!rad_pkg)
			add('api', 'error', 'api_enable is set but the RouterOS API needs wrt-hotspot-radius');
		else if (!state?.api)
			add('api', state?.running ? 'error' : 'info', `RouterOS API not listening on tcp/${g.api_port}`);
		else
			add('api', 'ok', `RouterOS API on tcp/${g.api_port} for ${who}; allow that port from the billing server in the firewall`);

		if (!length(g.api_password))
			add('api_login', 'warn', 'No api_user / api_password: only admin operators can log in to the API (and not with the old challenge login)');
	}

	// Capacity tiers (capacity.uc).
	let cp = state?.capacity;
	if (cp && cp.mode != 'off') {
		let over = cp.over_sessions || cp.over_users;
		add('capacity', (over || cp.low_memory || cp.low_flash) ? 'warn' : 'ok',
			sprintf('%s RAM tier, %s mode: %d/%d sessions, %d/%d user accounts%s%s%s', cp.tier?.label ?? '?', cp.mode,
				cp.sessions, cp.max_sessions, cp.users, cp.max_users,
				over ? ' - above the recommended capacity' : '',
				cp.low_memory ? ' - little free memory, the minimum is allowed (balanced or max mode fits more)' : '',
				cp.low_flash ? ' - little free flash for user accounts' : ''));
	}

	// Kernel tables that bound how many clients the router can carry.
	let num = (path) => int(trim(fs.readfile(path) ?? '0'));
	let ct_max = num('/proc/sys/net/netfilter/nf_conntrack_max'), ct_cnt = num('/proc/sys/net/netfilter/nf_conntrack_count');
	let n6 = num('/proc/sys/net/ipv6/neigh/default/gc_thresh3'), n4 = num('/proc/sys/net/ipv4/neigh/default/gc_thresh3');

	add('conntrack', (ct_max && ct_cnt > ct_max * 0.8) ? 'warn' : 'info',
		`Connection tracking: ${ct_cnt} of ${ct_max} entries in use (each client needs dozens)`);
	add('neigh', (n6 < 4096 || n4 < 2048) ? 'warn' : 'ok',
		`Neighbor table limits: IPv4 ${n4}, IPv6 ${n6} entries` + ((n6 < 4096) ? ' - too small for many IPv6 clients (see /etc/sysctl.d/12-wrthotspot.conf)' : ''));

	let tz = fs.readfile('/etc/TZ');
	add('timezone', 'info', `Time zone ${trim(tz ?? 'UTC')} (used by scheduled limitations)`);

	return out;
};
