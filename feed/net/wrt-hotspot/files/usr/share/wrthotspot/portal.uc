{%
// uhttpd ucode handler for the captive portal (runs in a forked child per
// request; uhttpd compiles it in template mode, hence the opening tag).
// Talks to hotspotd over ubus; never touches the dataplane itself.
'use strict';

import * as fs from 'fs';
import * as ubus from 'ubus';
import { load as load_config } from 'wrthotspot.config';
import { normalize_ip, ip_family, fmt_duration, fmt_bytes } from 'wrthotspot.util';
import * as tpl from 'wrthotspot.template';

const MIME = {
	html: 'text/html; charset=utf-8', css: 'text/css', js: 'application/javascript',
	png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif',
	svg: 'image/svg+xml', ico: 'image/x-icon', woff2: 'font/woff2', woff: 'font/woff', webp: 'image/webp',
	json: 'application/json', txt: 'text/plain; charset=utf-8',
};

const BUILTIN_PAGES = '/usr/share/wrthotspot/pages/default';
const MAX_BODY = 4096;		// a login form is a few hundred bytes; slow big bodies tie up workers
const COOKIE = 'wrthotspot';

// What OS connectivity probes expect once the client is online. Unauthenticated
// probes get the normal redirect, which is what pops up the login sheet.
const PROBES = {
	'/hotspot-detect.html': [ '200 OK', 'text/html', '<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>' ],
	'/library/test/success.html': [ '200 OK', 'text/html', '<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>' ],
	'/generate_204': [ '204 No Content', null, null ],
	'/gen_204': [ '204 No Content', null, null ],
	'/connecttest.txt': [ '200 OK', 'text/plain', 'Microsoft Connect Test' ],
	'/ncsi.txt': [ '200 OK', 'text/plain', 'Microsoft NCSI' ],
	'/success.txt': [ '200 OK', 'text/plain', 'success\n' ],
};

function send_response(status, headers, body) {
	let out = `Status: ${status}\r\n`;

	headers['Cache-Control'] ??= 'no-store, no-cache, must-revalidate';
	// A kept-alive connection could still be NATed to us after login.
	headers['Connection'] = 'close';

	// No value may end the header line: CR/LF from a request (dst=%0d%0a...)
	// would add headers or a body of the client's choosing.
	for (let k, v in headers)
		out += `${k}: ${replace(`${v}`, /[\r\n]/g, '')}\r\n`;

	uhttpd.send(out + '\r\n');

	if (body != null)
		uhttpd.send(body);
}

function redirect(url, headers) {
	send_response('302 Found', { ...(headers ?? {}), Location: url, 'Content-Type': 'text/html; charset=utf-8' },
		`<html><head><meta http-equiv="refresh" content="0; url=${tpl.escape_html(url)}"></head><body><a href="${tpl.escape_html(url)}">Continue</a></body></html>`);
}

function urldecode(s) {
	try {
		return uhttpd.urldecode(replace(s ?? '', '+', ' '));
	}
	catch (e) {
		return s;
	}
}

function urlencode(s) {
	return uhttpd.urlencode(`${s ?? ''}`);
}

function parse_query(qs) {
	let out = {};

	for (let pair in split(qs ?? '', '&')) {
		if (pair == '')
			continue;

		let i = index(pair, '=');
		let k = urldecode((i < 0) ? pair : substr(pair, 0, i));
		out[k] = (i < 0) ? '' : urldecode(substr(pair, i + 1));
	}

	return out;
}

function parse_cookies(h) {
	let out = {};

	for (let part in split(h ?? '', ';')) {
		let m = match(trim(part), /^([^=]+)=(.*)$/);
		if (m)
			out[m[1]] = m[2];
	}

	return out;
}

function read_body(env) {
	let len = int(env.CONTENT_LENGTH ?? 0);
	let body = '';

	if (len <= 0 || len > MAX_BODY)
		return '';

	while (length(body) < len) {
		let chunk = uhttpd.recv(len - length(body));

		if (chunk == null)
			break;

		body += chunk;
	}

	return body;
}

function host_without_port(h) {
	h = lc(h ?? '');

	if (substr(h, 0, 1) == '[')
		return substr(h, 1, index(h, ']') - 1);

	let i = index(h, ':');
	return (i >= 0 && index(substr(h, i + 1), ':') < 0) ? substr(h, 0, i) : h;
}

function portal_host(env, sp) {
	if (sp.dns_name)
		return sp.dns_name;

	let a = normalize_ip(env.SERVER_ADDR);
	return (ip_family(a) == 6) ? `[${a}]` : a;
}

function origin(scheme, host, port) {
	let dflt = (scheme == 'https') ? 443 : 80;
	return `${scheme}://${host}${(port == dflt) ? '' : `:${port}`}`;
}

// Where to send the client after login: only plain http(s) URLs with a host.
// "javascript:" and friends would run on the portal's origin, and control
// characters would end up in the Location header.
function safe_dst(v) {
	v = `${v ?? ''}`;

	// (POSIX classes: ucode regexes have no \x.. or \s inside brackets)
	return match(v, /^https?:\/\/[^\/?#[:space:]]+([\/?#][^[:space:]]*)?$/i) && !match(v, /[[:cntrl:]]/) ? v : '';
}

// True when the browser says the request comes from another site (Origin, or
// Referer when there is no Origin). Captive-portal assistants and plain links
// often send neither: that is not treated as cross-site.
function cross_site(env, ctx) {
	let src = env.HTTP_ORIGIN ?? env.HTTP_REFERER;

	if (src == null || src == '' || src == 'null')
		return src == 'null';	// "null": a sandboxed or opaque origin

	// authority part; host_without_port() handles "[v6]:port" and "host:port"
	let m = match(src, /^https?:\/\/([^\/?#]+)/i);
	let h = m ? host_without_port(m[1]) : null;

	return !(h && (h == host_without_port(ctx.host) || h == ctx.server_addr || h == lc(ctx.sp.dns_name ?? '')));
}

function page_path(sp, name) {
	if (!match(name, /^[A-Za-z0-9_.-]+(\/[A-Za-z0-9_.-]+)*$/) || index(name, '..') >= 0)
		return null;

	for (let dir in [ sp.html_directory, BUILTIN_PAGES ]) {
		let p = `${dir}/${name}`;
		let st = fs.stat(p);

		if (st?.type == 'file')
			return p;
	}

	return null;
}

function render_page(sp, name, vars, headers) {
	let p = page_path(sp, name);

	if (!p) {
		send_response('404 Not Found', { 'Content-Type': 'text/plain' }, `missing page ${name}\n`);
		return;
	}

	send_response('200 OK', { ...(headers ?? {}), 'Content-Type': 'text/html; charset=utf-8' }, tpl.render(fs.readfile(p), vars));
}

// Revalidated, not cached for a fixed time: an admin may replace the page set
// (same file names, new content) at any moment. The ETag (inode, mtime, size)
// changes with every replacement, even one within the same second.
function serve_static(env, sp, path) {
	let p = page_path(sp, path);

	if (!p || match(path, /\.html$/))
		return false;

	let ext = lc(match(path, /\.([A-Za-z0-9]+)$/)?.[1] ?? '');
	let st = fs.stat(p);
	let etag = sprintf('"%x-%x-%x"', st?.inode ?? 0, st?.mtime ?? 0, st?.size ?? 0);
	let headers = { 'Content-Type': MIME[ext] ?? 'application/octet-stream', 'Cache-Control': 'no-cache', ETag: etag };

	// (uhttpd maps only some headers to HTTP_*; the rest are in env.headers)
	if (env.headers?.['if-none-match'] == etag)
		send_response('304 Not Modified', headers, null);
	else
		send_response('200 OK', headers, fs.readfile(p));

	return true;
}

function variables(ctx, extra) {
	let c = ctx.client;
	let s = c?.session;
	let base = ctx.login_base;

	let v = {
		'hostname': ctx.host, 'identity': ctx.identity, 'server-name': c?.server ?? '',
		'server-address': ctx.server_addr, 'ip': ctx.ip, 'mac': c?.mac ?? '', 'mac-esc': urlencode(c?.mac),
		'logged-in': s ? 'yes' : 'no', 'username': s?.user ?? ctx.form.username ?? '', 'user-esc': urlencode(s?.user),
		'trial': ('trial' in ctx.sp.login_by) ? 'yes' : 'no',
		'login-by': s?.login_by ?? '',
		'link-login': `${base}/login?dst=${urlencode(ctx.dst)}`,
		'link-login-only': `${base}/login`,
		'link-logout': `${ctx.base}/logout`,
		'link-status': `${ctx.base}/status`,
		'link-orig': ctx.dst, 'link-orig-esc': urlencode(ctx.dst),
		'link-redirect': `${base}/login?dst=${urlencode(ctx.dst)}`,
		// CHAP is pointless (and MikroTik disables it) when the form goes over TLS.
		'chap-id': ('http-chap' in ctx.sp.login_by && !ctx.https_login) ? c?.chap_id : '',
		'chap-challenge': ('http-chap' in ctx.sp.login_by && !ctx.https_login) ? c?.chap_challenge : '',
		'error': ctx.error ?? '', 'error-orig': ctx.error ?? '',
		'session-id': s?.id ?? '',
		'uptime': s ? fmt_duration(s.uptime) : '', 'uptime-secs': s?.uptime ?? '',
		'session-time-left': (s?.session_time_left != null) ? fmt_duration(s.session_time_left) : '',
		'session-time-left-secs': s?.session_time_left ?? '',
		'idle-timeout': s ? fmt_duration(s.limits.idle_timeout) : '', 'idle-timeout-secs': s?.limits?.idle_timeout ?? '',
		'bytes-in': s?.bytes_in ?? '', 'bytes-out': s?.bytes_out ?? '',
		'bytes-in-nice': s ? fmt_bytes(s.bytes_in) : '', 'bytes-out-nice': s ? fmt_bytes(s.bytes_out) : '',
		'packets-in': s?.packets_in ?? '', 'packets-out': s?.packets_out ?? '',
		'limit-bytes-in': s?.limits?.bytes_in || '', 'limit-bytes-out': s?.limits?.bytes_out || '',
		'remain-bytes-in': s?.limits?.bytes_in ? max(0, s.limits.bytes_in - s.bytes_in) : '',
		'remain-bytes-out': s?.limits?.bytes_out ? max(0, s.limits.bytes_out - s.bytes_out) : '',
		'refresh-timeout': s ? fmt_duration(s.limits.status_autorefresh) : '',
		'refresh-timeout-secs': s?.limits?.status_autorefresh ?? '',
		'popup': 'false',
		'plain-passwd': ('http-pap' in ctx.sp.login_by || ctx.https_login) ? 'yes' : 'no',
		'http-status': '', 'var': ctx.form.var ?? '',
		'user-agent': ctx.env.HTTP_USER_AGENT ?? '',
		'host-ip': ctx.ip,
		'interface-name': c?.host?.dev ?? '',
		'domain': '', 'vlan-id': '', 'advert-pending': 'no',
		'ssl-login': ctx.https_login ? 'yes' : 'no',
		'ipv6': join(' ', c?.host?.ipv6 ?? []),
	};

	return { ...v, ...(extra ?? {}) };
}

function do_login(ctx, conn) {
	let f = ctx.form;
	let sp = ctx.sp;
	let req = { ip: ctx.ip, username: f.username ?? '', password: f.password ?? '' };

	// (only the form decides: an account may well be called "T-something").
	// MikroTik's stock trial link sends username=T-<the client's own MAC> and
	// no password; that exact name is a trial request.
	let mt_trial = ('trial' in sp.login_by) && !f.password && ctx.client?.mac &&
		lc(req.username) == `t-${lc(ctx.client.mac)}`;

	if (f.trial == 'yes' || mt_trial)
		req.method = 'trial';
	else if ('http-chap' in sp.login_by && !ctx.https_login && match(req.password, /^[0-9a-fA-F]{32}$/))
		req = { ...req, method: 'http-chap', chap_response: req.password };
	else
		req.method = 'http-pap';

	let res = conn.call('wrthotspot', 'login', req);

	// A 32-hex-digit plain password is legal too: retry as PAP if allowed.
	if (!res?.ok && req.method == 'http-chap' && 'http-pap' in sp.login_by)
		res = conn.call('wrthotspot', 'login', { ip: ctx.ip, username: req.username, password: req.password, method: 'http-pap' });

	return res ?? { ok: false, error: 'hotspot service unavailable' };
}

function cookie_header(res) {
	if (!res?.cookie)
		return {};

	return { 'Set-Cookie': `${COOKIE}=${res.cookie.token}; Max-Age=${res.cookie.max_age}; Path=/; HttpOnly; SameSite=Lax` };
}

function logged_in(ctx, res, headers) {
	render_page(ctx.sp, 'alogin.html', variables(ctx, { 'link-redirect': ctx.dst || `${ctx.base}/status` }), headers);
}

global.handle_request = function(env) {
	let conn = ubus.connect();

	if (!conn) {
		send_response('503 Service Unavailable', { 'Content-Type': 'text/plain' }, 'hotspot service unavailable\n');
		return;
	}

	let cfg = load_config();
	let g = cfg.global;
	let ip = normalize_ip(env.REMOTE_ADDR);
	let client = conn.call('wrthotspot', 'client', { ip });

	if (client && !client.found)
		client = null;

	let srv = cfg.servers[client?.server];
	let sp = cfg.server_profiles[srv?.profile] ?? cfg.server_profiles.default;
	let uri = env.REQUEST_URI ?? '/';
	let qpos = index(uri, '?');
	let path = (qpos >= 0) ? substr(uri, 0, qpos) : uri;
	let form = parse_query(env.QUERY_STRING);
	let is_https = (env.HTTPS == 'on');

	if (env.REQUEST_METHOD == 'POST' && match(env.CONTENT_TYPE ?? '', /^application\/x-www-form-urlencoded/))
		form = { ...form, ...parse_query(read_body(env)) };

	let host = portal_host(env, sp);
	let https_login = ('https' in sp.login_by) && g.ssl_certificate && fs.stat(g.ssl_certificate) && fs.stat(g.ssl_key);
	let base = origin(is_https ? 'https' : 'http', host, int(env.SERVER_PORT ?? g.portal_port));

	let ctx = {
		env, cfg, sp, ip, form, host, base, client, https_login,
		login_base: https_login ? origin('https', host, g.https_port) : base,
		identity: g.nas_identifier || 'WrtHotspot',
		server_addr: normalize_ip(env.SERVER_ADDR),
		dst: safe_dst(form.dst),
	};

	// Any request for a foreign host was redirected here by nftables.
	let req_host = host_without_port(env.HTTP_HOST);
	let ours = (req_host == lc(sp.dns_name ?? '')) || (req_host == ctx.server_addr) || (req_host == '');

	if (!ours) {
		let orig = `http://${env.HTTP_HOST}${uri}`;

		if (client?.session) {
			// Logged in meanwhile but this connection was still NATed to us.
			let p = PROBES[path];

			if (p)
				send_response(p[0], p[1] ? { 'Content-Type': p[1] } : {}, p[2]);
			else
				redirect(orig);
		}
		else {
			redirect(`${ctx.login_base}/login?dst=${urlencode(orig)}`);
		}

		return;
	}

	// RFC 8908 captive portal API.
	if (path == '/api/captive' || path == '/api.json') {
		let s = client?.session;
		let body = { captive: !s, 'user-portal-url': `${ctx.login_base}/login` };

		if (s) {
			body['venue-info-url'] = `${base}/status`;
			if (s.session_time_left != null)
				body['seconds-remaining'] = s.session_time_left;
			if (s.limits?.bytes_total)
				body['bytes-remaining'] = max(0, s.limits.bytes_total - s.bytes_in - s.bytes_out);
			body['can-extend-session'] = false;
		}

		send_response('200 OK', { 'Content-Type': 'application/captive+json' }, sprintf('%J', body));
		return;
	}

	if (path == '/' || path == '/login') {
		if (client?.session && env.REQUEST_METHOD != 'POST') {
			redirect(ctx.dst || `${base}/status`);
			return;
		}

		// login-by=https: the form (and the password) only travel over TLS.
		if (https_login && !is_https) {
			redirect(`${ctx.login_base}${uri}`);
			return;
		}

		if ((env.REQUEST_METHOD == 'POST' || form.username != null || form.trial == 'yes') && cross_site(env, ctx)) {
			// Another site submitting our login form (login CSRF): show the
			// page, log nobody in.
			ctx.error = 'please log in on this page';
		}
		else if (env.REQUEST_METHOD == 'POST' || form.username != null || form.trial == 'yes') {
			let res = do_login(ctx, conn);

			if (res.ok) {
				ctx.client = conn.call('wrthotspot', 'client', { ip }) ?? client;
				logged_in(ctx, res, cookie_header(res));
				return;
			}

			ctx.error = res.error;
			ctx.client = conn.call('wrthotspot', 'client', { ip }) ?? client;	// fresh CHAP challenge
		}
		else if ('cookie' in sp.login_by) {
			let token = parse_cookies(env.HTTP_COOKIE)[COOKIE];

			if (token && match(token, /^[0-9a-f]{32}$/)) {
				let res = conn.call('wrthotspot', 'login', { ip, method: 'cookie', cookie: token });

				if (res?.ok) {
					ctx.client = conn.call('wrthotspot', 'client', { ip }) ?? client;
					logged_in(ctx, res, {});
					return;
				}
			}
		}

		render_page(sp, 'login.html', variables(ctx));
		return;
	}

	if (path == '/status') {
		render_page(sp, client?.session ? 'status.html' : 'fstatus.html', variables(ctx));
		return;
	}

	if (path == '/logout') {
		let erase = { 'Set-Cookie': `${COOKIE}=; Max-Age=0; Path=/; HttpOnly; SameSite=Lax` };

		if (!client?.session) {
			render_page(sp, 'flogout.html', variables(ctx), erase);
			return;
		}

		// Another site linking to /logout (an <img>, a form) must not end the
		// session: show the status page with its logout button instead.
		if (cross_site(env, ctx)) {
			render_page(sp, 'status.html', variables(ctx));
			return;
		}

		let before = variables(ctx);
		conn.call('wrthotspot', 'logout', { ip, cause: 'user-request' });
		render_page(sp, 'logout.html', before, erase);
		return;
	}

	if (serve_static(env, sp, substr(path, 1)))
		return;

	send_response('404 Not Found', { 'Content-Type': 'text/plain' }, 'not found\n');
};
