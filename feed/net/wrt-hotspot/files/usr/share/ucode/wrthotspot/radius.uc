// RADIUS (RFC 2865/2866/2869/5176/3162/6911) for hotspotd:
//  - packet codec with a dictionary of standard, MikroTik (14988) and
//    WISPr (14122) attributes
//  - User-Password hiding, CHAP, request/response authenticators and
//    Message-Authenticator (HMAC-MD5, always sent: BlastRADIUS mitigation)
//  - an asynchronous client (retries, server failover, accounting backlog)
//  - a CoA / Disconnect-Request listener (RFC 5176)
'use strict';

import * as socket from 'socket';
import * as uloop from 'uloop';
import * as struct from 'struct';
import { md5 } from 'digest';
import { random_bytes, log, ip_family } from 'wrthotspot.util';

export const CODE = {
	ACCESS_REQUEST: 1, ACCESS_ACCEPT: 2, ACCESS_REJECT: 3,
	ACCOUNTING_REQUEST: 4, ACCOUNTING_RESPONSE: 5, ACCESS_CHALLENGE: 11,
	DISCONNECT_REQUEST: 40, DISCONNECT_ACK: 41, DISCONNECT_NAK: 42,
	COA_REQUEST: 43, COA_ACK: 44, COA_NAK: 45,
};

export const VENDOR_MIKROTIK = 14988;
export const VENDOR_WISPR = 14122;

// name: [ vendor, id, type ]
const DICT = {
	'User-Name': [ 0, 1, 'string' ],
	'User-Password': [ 0, 2, 'octets' ],
	'CHAP-Password': [ 0, 3, 'octets' ],
	'NAS-IP-Address': [ 0, 4, 'ipaddr' ],
	'NAS-Port': [ 0, 5, 'integer' ],
	'Service-Type': [ 0, 6, 'integer' ],
	'Framed-IP-Address': [ 0, 8, 'ipaddr' ],
	'Filter-Id': [ 0, 11, 'string' ],
	'Reply-Message': [ 0, 18, 'string' ],
	'State': [ 0, 24, 'octets' ],
	'Class': [ 0, 25, 'octets' ],
	'Session-Timeout': [ 0, 27, 'integer' ],
	'Idle-Timeout': [ 0, 28, 'integer' ],
	'Called-Station-Id': [ 0, 30, 'string' ],
	'Calling-Station-Id': [ 0, 31, 'string' ],
	'NAS-Identifier': [ 0, 32, 'string' ],
	'Proxy-State': [ 0, 33, 'octets' ],
	'Acct-Status-Type': [ 0, 40, 'integer' ],
	'Acct-Delay-Time': [ 0, 41, 'integer' ],
	'Acct-Input-Octets': [ 0, 42, 'integer' ],
	'Acct-Output-Octets': [ 0, 43, 'integer' ],
	'Acct-Session-Id': [ 0, 44, 'string' ],
	'Acct-Authentic': [ 0, 45, 'integer' ],
	'Acct-Session-Time': [ 0, 46, 'integer' ],
	'Acct-Input-Packets': [ 0, 47, 'integer' ],
	'Acct-Output-Packets': [ 0, 48, 'integer' ],
	'Acct-Terminate-Cause': [ 0, 49, 'integer' ],
	'Acct-Input-Gigawords': [ 0, 52, 'integer' ],
	'Acct-Output-Gigawords': [ 0, 53, 'integer' ],
	'Event-Timestamp': [ 0, 55, 'integer' ],
	'CHAP-Challenge': [ 0, 60, 'octets' ],
	'NAS-Port-Type': [ 0, 61, 'integer' ],
	'Port-Limit': [ 0, 62, 'integer' ],
	'Message-Authenticator': [ 0, 80, 'octets' ],
	'Acct-Interim-Interval': [ 0, 85, 'integer' ],
	'NAS-Port-Id': [ 0, 87, 'string' ],
	'NAS-IPv6-Address': [ 0, 95, 'ipv6addr' ],
	'Framed-IPv6-Prefix': [ 0, 97, 'ipv6prefix' ],
	'Error-Cause': [ 0, 101, 'integer' ],
	'Framed-IPv6-Address': [ 0, 168, 'ipv6addr' ],

	'Mikrotik-Recv-Limit': [ VENDOR_MIKROTIK, 1, 'integer' ],
	'Mikrotik-Xmit-Limit': [ VENDOR_MIKROTIK, 2, 'integer' ],
	'Mikrotik-Group': [ VENDOR_MIKROTIK, 3, 'string' ],
	'Mikrotik-Rate-Limit': [ VENDOR_MIKROTIK, 8, 'string' ],
	'Mikrotik-Realm': [ VENDOR_MIKROTIK, 9, 'string' ],
	'Mikrotik-Host-IP': [ VENDOR_MIKROTIK, 10, 'ipaddr' ],
	'Mikrotik-Mark-Id': [ VENDOR_MIKROTIK, 11, 'string' ],
	'Mikrotik-Advertise-URL': [ VENDOR_MIKROTIK, 12, 'string' ],
	'Mikrotik-Advertise-Interval': [ VENDOR_MIKROTIK, 13, 'integer' ],
	'Mikrotik-Recv-Limit-Gigawords': [ VENDOR_MIKROTIK, 14, 'integer' ],
	'Mikrotik-Xmit-Limit-Gigawords': [ VENDOR_MIKROTIK, 15, 'integer' ],
	'Mikrotik-Total-Limit': [ VENDOR_MIKROTIK, 17, 'integer' ],
	'Mikrotik-Total-Limit-Gigawords': [ VENDOR_MIKROTIK, 18, 'integer' ],
	'Mikrotik-Address-List': [ VENDOR_MIKROTIK, 19, 'string' ],

	'WISPr-Location-ID': [ VENDOR_WISPR, 1, 'string' ],
	'WISPr-Location-Name': [ VENDOR_WISPR, 2, 'string' ],
	'WISPr-Logoff-URL': [ VENDOR_WISPR, 3, 'string' ],
	'WISPr-Redirection-URL': [ VENDOR_WISPR, 4, 'string' ],
	'WISPr-Bandwidth-Min-Up': [ VENDOR_WISPR, 5, 'integer' ],
	'WISPr-Bandwidth-Min-Down': [ VENDOR_WISPR, 6, 'integer' ],
	'WISPr-Bandwidth-Max-Up': [ VENDOR_WISPR, 7, 'integer' ],
	'WISPr-Bandwidth-Max-Down': [ VENDOR_WISPR, 8, 'integer' ],
	'WISPr-Session-Terminate-Time': [ VENDOR_WISPR, 9, 'string' ],
	'WISPr-Session-Terminate-End-Of-Day': [ VENDOR_WISPR, 10, 'integer' ],
	'WISPr-Billing-Class-Of-Service': [ VENDOR_WISPR, 11, 'string' ],
};

// "vendor:id" -> name
const BY_ID = {};
for (let name, d in DICT)
	BY_ID[`${d[0]}:${d[1]}`] = name;

// RFC 2866 Acct-Status-Type / Acct-Terminate-Cause.
export const ACCT_START = 1;
export const ACCT_STOP = 2;
export const ACCT_INTERIM = 3;

export const TERMINATE_CAUSE = {
	'user-request': 1, 'lost-carrier': 2, 'keepalive-timeout': 2, 'idle-timeout': 4,
	'session-timeout': 5, 'uptime-limit': 5, 'admin-reset': 6, 'user-removed': 6,
	'traffic-limit': 10, 'nas-request': 10, 'nas-reboot': 11, 'new-login': 13,
};

// NAS-Port-Type names as in MikroTik's nas-port-type setting.
export const NAS_PORT_TYPE = { 'async': 0, 'sync': 1, 'virtual': 5, 'ethernet': 15, 'wireless-802.11': 19 };

/* ---------- primitives ---------- */

function bin_md5(s) {
	return hexdec(md5(s));
}

function xor(a, b) {
	let out = '';

	for (let i = 0; i < length(a); i++)
		out += chr(ord(a, i) ^ ord(b, i));

	return out;
}

function zeros(n) {
	let s = '';
	for (let i = 0; i < n; i++)
		s += '\0';
	return s;
}

// HMAC-MD5 (RFC 2104), built from two MD5 calls.
export function hmac_md5(key, msg) {
	if (length(key) > 64)
		key = bin_md5(key);

	key += zeros(64 - length(key));

	let ipad = '', opad = '';
	for (let i = 0; i < 64; i++) {
		ipad += chr(ord(key, i) ^ 0x36);
		opad += chr(ord(key, i) ^ 0x5c);
	}

	return bin_md5(opad + bin_md5(ipad + msg));
};

// RFC 2865 5.2 User-Password hiding (also used to reveal it in tests).
export function hide_password(password, secret, authenticator) {
	let p = password;
	let pad = (16 - (length(p) % 16)) % 16;

	if (length(p) == 0)
		pad = 16;

	p += zeros(pad);

	let out = '', prev = authenticator;

	for (let i = 0; i < length(p); i += 16) {
		let c = xor(substr(p, i, 16), bin_md5(secret + prev));
		out += c;
		prev = c;
	}

	return out;
};

export function unhide_password(hidden, secret, authenticator) {
	let out = '', prev = authenticator;

	for (let i = 0; i < length(hidden); i += 16) {
		let c = substr(hidden, i, 16);
		out += xor(c, bin_md5(secret + prev));
		prev = c;
	}

	return rtrim(out, '\0');
};

/* ---------- attribute codec ---------- */

function encode_value(type, v) {
	switch (type) {
	case 'integer':
		return struct.pack('!I', int(v) & 0xffffffff);

	case 'ipaddr':
		return join('', map(iptoarr(v) ?? [ 0, 0, 0, 0 ], (b) => chr(b)));

	case 'ipv6addr':
		return join('', map(iptoarr(v) ?? [], (b) => chr(b)));

	case 'ipv6prefix': {
		let m = match(v, /^([^\/]+)\/(\d+)$/);
		let a = m ? iptoarr(m[1]) : null;

		if (!a)
			return null;

		let bytes = int((int(m[2]) + 7) / 8);
		return chr(0) + chr(int(m[2])) + join('', map(slice(a, 0, bytes), (b) => chr(b)));
	}

	default:
		return `${v}`;
	}
}

function decode_value(type, raw) {
	switch (type) {
	case 'integer':
		return (length(raw) == 4) ? struct.unpack('!I', raw)[0] : null;

	case 'ipaddr':
	case 'ipv6addr': {
		let a = [];
		for (let i = 0; i < length(raw); i++)
			push(a, ord(raw, i));
		return arrtoip(a);
	}

	case 'ipv6prefix': {
		let bits = ord(raw, 1), a = [];
		for (let i = 2; i < 18; i++)
			push(a, (i < length(raw)) ? ord(raw, i) : 0);
		return `${arrtoip(a)}/${bits}`;
	}

	default:
		return raw;
	}
}

function encode_attr(name, value) {
	let d = DICT[name];

	if (!d)
		die(`unknown RADIUS attribute ${name}`);

	let data = encode_value(d[2], value);

	if (data == null)
		return '';

	if (length(data) > 253 - (d[0] ? 6 : 0))
		data = substr(data, 0, 253 - (d[0] ? 6 : 0));

	if (!d[0])
		return chr(d[1]) + chr(length(data) + 2) + data;

	let vsa = chr(d[1]) + chr(length(data) + 2) + data;
	return chr(26) + chr(length(vsa) + 6) + struct.pack('!I', d[0]) + vsa;
}

// attrs: [ [ name, value ], ... ]  -> wire bytes
export function encode_attrs(attrs) {
	let out = '';

	for (let a in attrs)
		if (a[1] != null)
			out += encode_attr(a[0], a[1]);

	return out;
};

// -> [ { name, vendor, id, value, raw } ]
export function decode_attrs(buf) {
	let out = [];
	let pos = 0;

	while (pos + 2 <= length(buf)) {
		let id = ord(buf, pos), len = ord(buf, pos + 1);

		if (len < 2 || pos + len > length(buf))
			return null;

		let raw = substr(buf, pos + 2, len - 2);
		pos += len;

		if (id == 26 && length(raw) >= 6) {
			let vendor = struct.unpack('!I', substr(raw, 0, 4))[0];
			let vpos = 4;

			while (vpos + 2 <= length(raw)) {
				let vid = ord(raw, vpos), vlen = ord(raw, vpos + 1);

				if (vlen < 2 || vpos + vlen > length(raw))
					break;

				let vraw = substr(raw, vpos + 2, vlen - 2);
				let name = BY_ID[`${vendor}:${vid}`];

				push(out, { name, vendor, id: vid, raw: vraw, value: name ? decode_value(DICT[name][2], vraw) : vraw });
				vpos += vlen;
			}

			continue;
		}

		let name = BY_ID[`0:${id}`];
		push(out, { name, vendor: 0, id, raw, value: name ? decode_value(DICT[name][2], raw) : raw });
	}

	return out;
};

/* ---------- packets ---------- */

function header(code, id, len, auth) {
	return chr(code) + chr(id) + struct.pack('!H', len) + auth;
}

// Insert a Message-Authenticator computed with `auth` in the header
// (request authenticator, or the original request's for responses).
function sign_message_auth(code, id, attrs_bin, auth, secret) {
	let ma = chr(80) + chr(18);
	let body = attrs_bin + ma + zeros(16);
	let len = 20 + length(body);
	let mac = hmac_md5(secret, header(code, id, len, auth) + body);

	return attrs_bin + ma + mac;
}

// Access-Request: random authenticator; passwords hidden with it.
export function access_request(id, attrs, secret) {
	let auth = random_bytes(16);
	let list = [];

	for (let a in attrs) {
		if (a[0] == 'User-Password')
			push(list, [ 'User-Password', hide_password(a[1], secret, auth) ]);
		else
			push(list, a);
	}

	let body = sign_message_auth(CODE.ACCESS_REQUEST, id, encode_attrs(list), auth, secret);
	return { packet: header(CODE.ACCESS_REQUEST, id, 20 + length(body), auth) + body, auth };
};

// Accounting-Request / CoA / Disconnect requests: MD5(header with zero auth + attrs + secret).
export function signed_request(code, id, attrs, secret, with_ma) {
	let body = encode_attrs(attrs);

	if (with_ma)
		body = sign_message_auth(code, id, body, zeros(16), secret);

	let len = 20 + length(body);
	let auth = bin_md5(header(code, id, len, zeros(16)) + body + secret);

	return { packet: header(code, id, len, auth) + body, auth };
};

// Responses (Access-Accept/Reject, Accounting-Response, CoA/Disconnect ACK/NAK).
export function response(code, id, req_auth, attrs, secret) {
	let body = sign_message_auth(code, id, encode_attrs(attrs), req_auth, secret);
	let len = 20 + length(body);
	let auth = bin_md5(header(code, id, len, req_auth) + body + secret);

	return header(code, id, len, auth) + body;
};

// -> { code, id, auth, attrs } or null for garbage
export function parse(buf) {
	if (length(buf) < 20)
		return null;

	let code = ord(buf, 0), id = ord(buf, 1);
	let len = struct.unpack('!H', substr(buf, 2, 2))[0];

	if (len < 20 || len > length(buf) || len > 4096)
		return null;

	let attrs = decode_attrs(substr(buf, 20, len - 20));

	if (attrs == null)
		return null;

	return { code, id, len, auth: substr(buf, 4, 16), attrs, raw: substr(buf, 0, len) };
};

// First value of an attribute, or all values with `all`.
export function attr(pkt, name, all) {
	let vals = map(filter(pkt.attrs, (a) => a.name == name), (a) => a.value);
	return all ? vals : vals[0];
};

// Check a Message-Authenticator if present; `required` makes it mandatory.
function verify_message_auth(pkt, auth_for_hmac, secret, required) {
	let idx = -1, pos = 20;

	// Locate the attribute in the raw packet to zero it.
	while (pos + 2 <= pkt.len) {
		let id = ord(pkt.raw, pos), len = ord(pkt.raw, pos + 1);

		if (len < 2)
			break;

		if (id == 80 && len == 18) {
			idx = pos;
			break;
		}

		pos += len;
	}

	if (idx < 0)
		return !required;

	let got = substr(pkt.raw, idx + 2, 16);
	let zeroed = substr(pkt.raw, 0, 4) + auth_for_hmac + substr(pkt.raw, 20, idx + 2 - 20) + zeros(16) + substr(pkt.raw, idx + 18);

	return hmac_md5(secret, zeroed) === got;
}

// Response to one of our requests.
export function verify_response(pkt, req_auth, secret, require_ma) {
	let expect = bin_md5(substr(pkt.raw, 0, 4) + req_auth + substr(pkt.raw, 20) + secret);

	if (expect !== pkt.auth)
		return false;

	return verify_message_auth(pkt, req_auth, secret, require_ma);
};

// Accounting/CoA/Disconnect request received or sent.
export function verify_signed_request(pkt, secret, require_ma) {
	let expect = bin_md5(substr(pkt.raw, 0, 4) + zeros(16) + substr(pkt.raw, 20) + secret);

	if (expect !== pkt.auth)
		return false;

	return verify_message_auth(pkt, zeros(16), secret, require_ma);
};

/* ---------- helpers for callers ---------- */

// 64-bit counters -> [ octets, gigawords ]
export function split64(n) {
	n = int(n ?? 0);
	return [ n % 4294967296, int(n / 4294967296) ];
};

export function join64(octets, gigawords) {
	return int(octets ?? 0) + int(gigawords ?? 0) * 4294967296;
};

// MikroTik radius-mac-format: "XX:XX:XX:XX:XX:XX", "xx-xx-...", "XXXXXXXXXXXX", "XXXX.XXXX.XXXX", ...
export function format_mac(mac, fmt) {
	let hex = replace(mac, /:/g, '');
	let out = '', j = 0;

	fmt ??= 'XX:XX:XX:XX:XX:XX';

	for (let i = 0; i < length(fmt); i++) {
		let c = substr(fmt, i, 1);

		if (c == 'X')
			out += uc(substr(hex, j++, 1));
		else if (c == 'x')
			out += lc(substr(hex, j++, 1));
		else
			out += c;
	}

	return out;
};

function days_from_civil(y, m, d) {
	y -= (m <= 2) ? 1 : 0;
	let era = int((y >= 0 ? y : y - 399) / 400);
	let yoe = y - era * 400;
	let doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1;
	let doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy;
	return era * 146097 + doe - 719468;
}

// WISPr-Session-Terminate-Time: ISO 8601, e.g. "2026-10-18T20:00:00+05:00".
export function parse_iso8601(s) {
	let m = match(s ?? '', /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(Z|([+-])(\d{2}):?(\d{2}))?$/);

	if (!m)
		return null;

	let t = days_from_civil(int(m[1]), int(m[2]), int(m[3])) * 86400 + int(m[4]) * 3600 + int(m[5]) * 60 + int(m[6]);

	if (m[8])
		t -= ((m[8] == '-') ? -1 : 1) * (int(m[9]) * 3600 + int(m[10]) * 60);

	return t;
};

/* ---------- client ---------- */

function server_addr(address, port) {
	// One dual-stack AF_INET6 socket: IPv4 servers become v4-mapped.
	return (ip_family(address) == 6) ? `[${address}]:${port}` : `[::ffff:${address}]:${port}`;
}

function same_peer(from, address, port) {
	let a = from.address;

	if (substr(a, 0, 7) == '::ffff:')
		a = substr(a, 7);

	return from.port == port && (a == address || arrtoip(iptoarr(a) ?? []) == arrtoip(iptoarr(address) ?? []));
}

// servers: [ { address, secret, auth_port, acct_port, timeout (ms), retries, require_message_auth } ]
export function client() {
	let servers = [];
	let sock = null, handle = null;
	let pending = {};		// id -> request
	let next_id = int(ord(random_bytes(1), 0));
	let backlog = [];		// accounting requests no server accepted yet
	let backlog_timer = null;
	let self;

	function free_id() {
		for (let n = 0; n < 256; n++) {
			let id = (next_id + n) % 256;

			if (!pending[id]) {
				next_id = (id + 1) % 256;
				return id;
			}
		}

		return null;
	}

	function on_packet(data, from) {
		let pkt = parse(data);

		if (!pkt)
			return;

		let r = pending[pkt.id];

		if (!r)
			return;

		let srv = r.srv;
		let port = (r.kind == 'acct') ? srv.acct_port : srv.auth_port;

		if (!same_peer(from, srv.address, port))
			return;

		if (!verify_response(pkt, r.auth, srv.secret, srv.require_message_auth && r.kind == 'auth')) {
			log('warn', 'RADIUS: bad authenticator from %s (wrong secret?)', srv.address);
			return;
		}

		r.timer.cancel();
		delete pending[pkt.id];
		r.cb(pkt, null);
	}

	function ensure_socket() {
		if (sock)
			return true;

		sock = socket.create(socket.AF_INET6, socket.SOCK_DGRAM | socket.SOCK_NONBLOCK);

		if (!sock) {
			log('error', 'RADIUS: cannot create socket: %s', socket.error());
			return false;
		}

		sock.setopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, false);
		sock.bind('[::]:0');

		handle = uloop.handle(sock.fileno(), () => {
			while (true) {
				let from = {};
				let data = sock.recv(4096, 0, from);

				if (data == null)
					break;

				on_packet(data, from);
			}
		}, uloop.ULOOP_READ);

		return true;
	}

	function send(r) {
		let srv = r.srv;
		let port = (r.kind == 'acct') ? srv.acct_port : srv.auth_port;

		sock.send(r.packet, 0, server_addr(srv.address, port));
	}

	// Try servers in order, each with `retries` retransmissions.
	function start(kind, attrs, cb, server_idx) {
		if (!length(servers))
			return cb(null, 'no RADIUS server configured');

		if (server_idx >= length(servers))
			return cb(null, 'RADIUS server timeout');

		if (!ensure_socket())
			return cb(null, 'RADIUS socket error');

		let srv = servers[server_idx];
		let id = free_id();

		if (id == null)
			return cb(null, 'too many outstanding RADIUS requests');

		let p = (kind == 'auth')
			? access_request(id, attrs, srv.secret)
			: signed_request(CODE.ACCOUNTING_REQUEST, id, attrs, srv.secret, false);

		let r = { kind, srv, id, packet: p.packet, auth: p.auth, tries: 0, cb };

		r.timer = uloop.timer(srv.timeout, () => {
			if (++r.tries <= srv.retries) {
				send(r);
				r.timer.set(srv.timeout);
				return;
			}

			delete pending[id];
			log('warn', 'RADIUS: no answer from %s:%d', srv.address, (kind == 'acct') ? srv.acct_port : srv.auth_port);
			start(kind, attrs, cb, server_idx + 1);
		});

		pending[id] = r;
		send(r);
	}

	function flush_backlog() {
		let items = backlog;
		backlog = [];

		for (let attrs in items)
			self.accounting(attrs, null);
	}

	self = {
		set_servers: function(list) {
			servers = list;
		},

		have_servers: function() {
			return length(servers) > 0;
		},

		// cb(pkt | null, err)
		authenticate: function(attrs, cb) {
			start('auth', attrs, cb, 0);
		},

		// Accounting must not get lost: unanswered requests are queued and
		// retried every minute (bounded so a dead server can't eat memory).
		accounting: function(attrs, cb) {
			start('acct', attrs, (pkt, err) => {
				if (!pkt) {
					if (length(backlog) < 1000)
						push(backlog, attrs);

					backlog_timer ??= uloop.timer(60000, () => {
						backlog_timer = null;
						flush_backlog();
					});
				}

				if (cb)
					cb(pkt, err);
			}, 0);
		},

		backlog: () => length(backlog),
	};

	return self;
};

/* ---------- CoA / Disconnect listener (RFC 5176) ---------- */

// handler(pkt, srv) -> [ code, attrs ]   (srv = the configured server it came from)
export function coa_server(port, servers_fn, handler) {
	let s = socket.create(socket.AF_INET6, socket.SOCK_DGRAM | socket.SOCK_NONBLOCK);

	if (!s) {
		log('error', 'CoA: cannot create socket: %s', socket.error());
		return null;
	}

	s.setopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, false);
	s.setopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, true);

	if (!s.bind(`[::]:${port}`)) {
		log('error', 'CoA: cannot bind port %d: %s', port, socket.error());
		s.close();
		return null;
	}

	let h = uloop.handle(s.fileno(), () => {
		while (true) {
			let from = {};
			let data = s.recv(4096, 0, from);

			if (data == null)
				break;

			let pkt = parse(data);

			if (!pkt || (pkt.code != CODE.DISCONNECT_REQUEST && pkt.code != CODE.COA_REQUEST))
				continue;

			let addr = (substr(from.address, 0, 7) == '::ffff:') ? substr(from.address, 7) : from.address;
			let srv = null;

			for (let x in servers_fn())
				if (arrtoip(iptoarr(x.address) ?? []) == arrtoip(iptoarr(addr) ?? []))
					srv = x;

			if (!srv) {
				log('warn', 'CoA: request from unknown client %s ignored', addr);
				continue;
			}

			if (!verify_signed_request(pkt, srv.secret, srv.require_message_auth)) {
				log('warn', 'CoA: bad authenticator from %s', addr);
				continue;
			}

			let res = handler(pkt, srv);
			let reply = response(res[0], pkt.id, pkt.auth, res[1] ?? [], srv.secret);

			s.send(reply, 0, (ip_family(addr) == 6) ? `[${addr}]:${from.port}` : `[::ffff:${addr}]:${from.port}`);
		}
	}, uloop.ULOOP_READ);

	return { close: () => { h.delete(); s.close(); } };
};
