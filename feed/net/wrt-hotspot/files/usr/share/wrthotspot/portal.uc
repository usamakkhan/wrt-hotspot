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
	svg: 'image/svg+xml', ico: 'image/x-icon', woff2: 'font/woff2', json: 'application/json',
	txt: 'text/plain; charset=utf-8',
};

const BUILTIN_PAGES = '/usr/share/wrthotspot/pages/default';
const MAX_BODY = 16384;

function send_response(status, headers, body) {
	let out = `Status: ${status}\r\n`;

	headers['Cache-Control'] ??= 'no-store, no-cache, must-revalidate';
	// A kept-alive connection could still be NATed to us after login.
	headers['Connection'] = 'close';

	for (let k, v in headers)
		out += `${k}: ${v}\r\n`;

	uhttpd.send(out + '\r\n');

	if (body != null)
		uhttpd.send(body);
}

function redirect(url) {
	send_response('302 Found', { Location: url, 'Content-Type': 'text/html; charset=utf-8' },
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

function render_page(sp, name, vars, status) {
	let p = page_path(sp, name);

	if (!p) {
		send_response('404 Not Found', { 'Content-Type': 'text/plain' }, `missing page ${name}\n`);
		return;
	}

	send_response(status ?? '200 OK', { 'Content-Type': 'text/html; charset=utf-8' }, tpl.render(fs.readfile(p), vars));
}

function serve_static(sp, path) {
	let p = page_path(sp, path);

	if (!p || match(path, /\.html$/))
		return false;

	let ext = lc(match(path, /\.([A-Za-z0-9]+)$/)?.[1] ?? '');
	send_response('200 OK', { 'Content-Type': MIME[ext] ?? 'application/octet-stream', 'Cache-Control': 'max-age=3600' }, fs.readfile(p));
	return true;
}

function variables(ctx, extra) {
	let c = ctx.client;
	let s = c?.session;
	let base = ctx.base;

	let v = {
		'hostname': ctx.host, 'identity': ctx.identity, 'server-name': c?.server ?? '',
		'server-address': ctx.server_addr, 'ip': ctx.ip, 'mac': c?.mac ?? '', 'mac-esc': urlencode(c?.mac),
		'logged-in': s ? 'yes' : 'no', 'username': s?.user ?? ctx.form.username ?? '', 'user-esc': urlencode(s?.user),
		'trial': ('trial' in ctx.sp.login_by) ? 'yes' : 'no',
		'login-by': s?.login_by ?? '',
		'link-login': `${base}/login?dst=${urlencode(ctx.dst)}`,
		'link-login-only': `${base}/login`,
		'link-logout': `${base}/logout`,
		'link-status': `${base}/status`,
		'link-orig': ctx.dst, 'link-orig-esc': urlencode(ctx.dst),
		'link-redirect': `${base}/login?dst=${urlencode(ctx.dst)}`,
		'chap-id': ('http-chap' in ctx.sp.login_by) ? c?.chap_id : '',
		'chap-challenge': ('http-chap' in ctx.sp.login_by) ? c?.chap_challenge : '',
		'error': ctx.error ?? '', 'error-orig': ctx.error ?? '',
		'session-id': s?.id ?? '',
		'uptime': s ? fmt_duration(s.uptime) : '', 'uptime-secs': s?.uptime ?? '',
		'session-time-left': (s?.session_time_left != null) ? fmt_duration(s.session_time_left) : '',
		'session-time-left-secs': s?.session_time_left ?? '',
		'idle-timeout': s ? fmt_duration(s.limits.idle_timeout) : '', 'idle-timeout-secs': s?.limits?.idle_timeout ?? '',
		'bytes-in': s?.bytes_in ?? '', 'bytes-out': s?.bytes_out ?? '',
		'bytes-in-nice': s ? fmt_bytes(s.bytes_in) : '', 'bytes-out-nice': s ? fmt_bytes(s.bytes_out) : '',
		'packets-in': s?.packets_in ?? '', 'packets-out': s?.packets_out ?? '',
		'refresh-timeout': s ? fmt_duration(s.limits.status_autorefresh) : '',
		'refresh-timeout-secs': s?.limits?.status_autorefresh ?? '',
		'popup': 'false',
		'plain-passwd': ('http-pap' in ctx.sp.login_by) ? 'yes' : 'no',
		'http-status': '', 'var': ctx.form.var ?? '',
		'user-agent': ctx.env.HTTP_USER_AGENT ?? '',
		'host-ip': ctx.ip,
		'ssl-login': 'no',
		'ipv6': join(' ', c?.host?.ipv6 ?? []),
	};

	return { ...v, ...(extra ?? {}) };
}

function do_login(ctx, conn) {
	let f = ctx.form;
	let sp = ctx.sp;
	let req = { ip: ctx.ip, username: f.username ?? '', password: f.password ?? '' };

	if (f.trial == 'yes' || match(req.username, /^T-/))
		req.method = 'trial';
	else if ('http-chap' in sp.login_by && match(req.password, /^[0-9a-fA-F]{32}$/))
		req = { ...req, method: 'http-chap', chap_response: req.password };
	else
		req.method = 'http-pap';

	let res = conn.call('wrthotspot', 'login', req);

	// A 32-hex-digit plain password is legal too: retry as PAP if allowed.
	if (!res?.ok && req.method == 'http-chap' && 'http-pap' in sp.login_by)
		res = conn.call('wrthotspot', 'login', { ip: ctx.ip, username: req.username, password: req.password, method: 'http-pap' });

	return res ?? { ok: false, error: 'hotspot service unavailable' };
}

global.handle_request = function(env) {
	let conn = ubus.connect();

	if (!conn) {
		send_response('503 Service Unavailable', { 'Content-Type': 'text/plain' }, 'hotspot service unavailable\n');
		return;
	}

	let cfg = load_config();
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

	if (env.REQUEST_METHOD == 'POST' && match(env.CONTENT_TYPE ?? '', /^application\/x-www-form-urlencoded/))
		form = { ...form, ...parse_query(read_body(env)) };

	let host = portal_host(env, sp);
	let port = int(env.SERVER_PORT ?? cfg.global.portal_port);
	let base = `http://${host}${(port == 80) ? '' : `:${port}`}`;

	let ctx = {
		env, cfg, sp, ip, form, host, base, client,
		identity: cfg.global.nas_identifier || 'WrtHotspot',
		server_addr: normalize_ip(env.SERVER_ADDR),
		dst: form.dst ?? '',
	};

	// Any request for a foreign host was redirected here by nftables:
	// send the browser to the login page, remembering where it wanted to go.
	let req_host = host_without_port(env.HTTP_HOST);
	let ours = (req_host == lc(sp.dns_name ?? '')) || (req_host == ctx.server_addr) || (req_host == '');

	if (!ours) {
		let orig = `http://${env.HTTP_HOST}${uri}`;

		if (client?.session)
			redirect(orig);		// logged in meanwhile, the new connection will pass
		else
			redirect(`${base}/login?dst=${urlencode(orig)}`);

		return;
	}

	// RFC 8908 captive portal API.
	if (path == '/api/captive' || path == '/api.json') {
		let s = client?.session;
		let body = { captive: !s, 'user-portal-url': `${base}/login` };

		if (s) {
			body['venue-info-url'] = `${base}/status`;
			if (s.session_time_left != null)
				body['seconds-remaining'] = s.session_time_left;
			body['can-extend-session'] = false;
		}

		send_response('200 OK', { 'Content-Type': 'application/captive+json' }, sprintf('%J', body));
		return;
	}

	if (path == '/' || path == '/login') {
		if (client?.session && env.REQUEST_METHOD != 'POST') {
			if (ctx.dst)
				redirect(ctx.dst);
			else
				redirect(`${base}/status`);
			return;
		}

		if (env.REQUEST_METHOD == 'POST' || form.username != null || form.trial == 'yes') {
			let res = do_login(ctx, conn);

			if (res.ok) {
				ctx.client = conn.call('wrthotspot', 'client', { ip }) ?? client;
				render_page(sp, 'alogin.html', variables(ctx, { 'link-redirect': ctx.dst || `${base}/status` }));
				return;
			}

			ctx.error = res.error;
			ctx.client = conn.call('wrthotspot', 'client', { ip }) ?? client;	// fresh CHAP challenge
		}

		render_page(sp, 'login.html', variables(ctx));
		return;
	}

	if (path == '/status') {
		render_page(sp, client?.session ? 'status.html' : 'fstatus.html', variables(ctx));
		return;
	}

	if (path == '/logout') {
		if (!client?.session) {
			render_page(sp, 'flogout.html', variables(ctx));
			return;
		}

		let before = variables(ctx);
		conn.call('wrthotspot', 'logout', { ip, cause: 'user-request' });
		render_page(sp, 'logout.html', before);
		return;
	}

	if (serve_static(sp, substr(path, 1)))
		return;

	send_response('404 Not Found', { 'Content-Type': 'text/plain' }, 'not found\n');
};
