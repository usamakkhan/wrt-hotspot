'use strict';
'require baseclass';
'require rpc';

/* RPC to hotspotd (ubus object "wrthotspot") */

var callStatus = rpc.declare({ object: 'wrthotspot', method: 'status' });
var callSessions = rpc.declare({ object: 'wrthotspot', method: 'sessions', expect: { sessions: [] } });
var callHosts = rpc.declare({ object: 'wrthotspot', method: 'hosts', expect: { hosts: [] } });
var callCookies = rpc.declare({ object: 'wrthotspot', method: 'cookies' });
var callLogout = rpc.declare({ object: 'wrthotspot', method: 'logout', params: [ 'mac', 'user', 'id', 'cause' ] });
// Paged: { users, total, offset }.
var callUsers = rpc.declare({ object: 'wrthotspot', method: 'user_list', params: [ 'offset', 'limit', 'search' ] });
var callUserSet = rpc.declare({
	object: 'wrthotspot', method: 'user_set',
	params: [ 'name', 'password', 'profile', 'server', 'mac', 'limit_uptime', 'limit_bytes_in',
		'limit_bytes_out', 'limit_bytes_total', 'disabled', 'comment', 'email', 'force' ]
});
var callUserRemove = rpc.declare({ object: 'wrthotspot', method: 'user_remove', params: [ 'name' ] });
var callUserReset = rpc.declare({ object: 'wrthotspot', method: 'user_reset_counters', params: [ 'name' ] });
var callCookieRemove = rpc.declare({ object: 'wrthotspot', method: 'cookie_remove', params: [ 'mac', 'user' ] });
var callCheck = rpc.declare({ object: 'wrthotspot', method: 'check', expect: { checks: [] } });
var callSetup = rpc.declare({ object: 'wrthotspot', method: 'setup', params: [ 'network' ] });
var callFlush = rpc.declare({ object: 'wrthotspot', method: 'flush' });
var callReload = rpc.declare({ object: 'wrthotspot', method: 'reload' });

var LOGIN_METHODS = [
	[ 'http-chap', _('HTTP CHAP') ], [ 'http-pap', _('HTTP PAP') ], [ 'https', _('HTTPS') ],
	[ 'cookie', _('HTTP cookie') ], [ 'mac-cookie', _('MAC cookie') ], [ 'mac', _('MAC') ], [ 'trial', _('Trial') ]
];

var UNITS = { '': 1, k: 1e3, m: 1e6, g: 1e9 };

/* MikroTik rate-limit parser, mirrors hotspotd's shaper.uc. */
function parseRate(v) {
	var m = String(v).toLowerCase().match(/^([0-9]+(\.[0-9]+)?)([kmg]?)(bps|bit)?$/);
	return m ? Math.floor(parseFloat(m[1]) * UNITS[m[3]]) : null;
}

function parseRateLimit(s) {
	if (s == null || String(s).trim() == '')
		return null;

	var f = String(s).trim().split(/\s+/);

	if (f.length > 6)
		return false;

	function pair(x, conv) {
		if (x == null)
			return [ 0, 0 ];

		var p = x.split('/');
		return [ conv(p[0]), conv(p.length > 1 ? p[1] : p[0]) ];
	}

	var time = function(x) { return /^[0-9]+s?$/.test(x) ? parseInt(x) : null; };
	var parts = [ pair(f[0], parseRate), pair(f[1], parseRate), pair(f[2], parseRate), pair(f[3], time), null, pair(f[5], parseRate) ];

	for (var i = 0; i < parts.length; i++)
		if (parts[i] && (parts[i][0] == null || parts[i][1] == null))
			return false;

	if (f[4] != null && !/^[1-8]$/.test(f[4]))
		return false;

	return { rx: parts[0][0], tx: parts[0][1] };
}

return baseclass.extend({
	status: callStatus,
	sessions: callSessions,
	hosts: callHosts,
	cookies: callCookies,
	logout: callLogout,
	users: callUsers,
	userSet: callUserSet,
	userRemove: callUserRemove,
	userReset: callUserReset,
	cookieRemove: callCookieRemove,
	check: callCheck,
	setup: callSetup,
	flush: callFlush,
	reload: callReload,

	// LuCI puts string children in with innerHTML: every value that comes from
	// users, RADIUS or the network goes through this.
	h: function(v) {
		return '%h'.format(v == null ? '' : String(v));
	},

	loginMethods: LOGIN_METHODS,
	parseRateLimit: parseRateLimit,

	fmtBytes: function(n) {
		n = +n || 0;

		if (n >= 1073741824) return '%.1f GiB'.format(n / 1073741824);
		if (n >= 1048576) return '%.1f MiB'.format(n / 1048576);
		if (n >= 1024) return '%.1f KiB'.format(n / 1024);

		return '%d B'.format(n);
	},

	fmtRate: function(bps) {
		bps = +bps || 0;

		if (bps >= 1e9) return '%.1f Gbit/s'.format(bps / 1e9);
		if (bps >= 1e6) return '%.1f Mbit/s'.format(bps / 1e6);
		if (bps >= 1e3) return '%.0f kbit/s'.format(bps / 1e3);

		return '%d bit/s'.format(bps);
	},

	fmtDuration: function(s) {
		s = +s || 0;

		if (s <= 0)
			return '0s';

		var out = '', units = [ [ 'w', 604800 ], [ 'd', 86400 ], [ 'h', 3600 ], [ 'm', 60 ], [ 's', 1 ] ];

		units.forEach(function(u) {
			if (s >= u[1]) {
				out += Math.floor(s / u[1]) + u[0];
				s %= u[1];
			}
		});

		return out;
	},

	/* form validators: return true or an error string */

	validateDuration: function(section_id, value) {
		if (value == null || value === '' || /^(none|[0-9]+|([0-9]+[wdhms])+|[0-9]+:[0-9]{1,2}:[0-9]{1,2})$/i.test(value))
			return true;

		return _('Use e.g. 30m, 1h30m, 2d, 00:30:00 or a number of seconds');
	},

	validateSize: function(section_id, value) {
		if (value == null || value === '' || /^[0-9]+(\.[0-9]+)?[kmgt]?i?b?$/i.test(value))
			return true;

		return _('Use bytes or e.g. 500k, 100M, 2G');
	},

	validateRateLimit: function(section_id, value) {
		if (value == null || value === '' || parseRateLimit(value))
			return true;

		return _('MikroTik format: rx/tx [rx-burst/tx-burst [rx-threshold/tx-threshold [rx-time/tx-time [priority [rx-min/tx-min]]]]], e.g. 2M/10M');
	},

	validateClock: function(section_id, value) {
		if (value == null || value === '' || /^([01]?[0-9]|2[0-4]):[0-5][0-9](:[0-5][0-9])?$/.test(value))
			return true;

		return _('Use HH:MM');
	},

	rateLimitHelp: _('MikroTik syntax, rx = upload, tx = download, bits/s with k/M/G: <code>rx/tx [rx-burst/tx-burst [rx-threshold/tx-threshold [rx-time/tx-time [priority [rx-min/tx-min]]]]]</code>, e.g. <code>2M/10M</code> or <code>1M/4M 2M/8M 768k/3M 8/8</code>.')
});
