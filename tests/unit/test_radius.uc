'use strict';
import { suite, eq, ok, done } from 'assert';
const r = require('wrthotspot.radius');	// a script (optional package), not a module

suite('radius');

// RFC 2104 test vectors.
let key = ''; for (let i = 0; i < 16; i++) key += chr(0x0b);
eq(hexenc(r.hmac_md5(key, 'Hi There')), '9294727a3638bb1c13f48ef8158bfc9d', 'hmac-md5 vector 1');
eq(hexenc(r.hmac_md5('Jefe', 'what do ya want for nothing?')), '750c783e6ab0b503eaa86e310a5db738', 'hmac-md5 vector 2');
let k3 = ''; for (let i = 0; i < 80; i++) k3 += chr(0xaa);
eq(hexenc(r.hmac_md5(k3, 'Test Using Larger Than Block-Size Key - Hash Key First')), '6b1ab7fe4bd7bf8f0b62e6ce61b9d0cd', 'hmac-md5 long key');

// Password hiding round trip, incl. > 16 bytes and empty.
let auth = 'ABCDEFGHIJKLMNOP';
for (let pw in [ 'secret', 'exactly-16-chars', 'a much longer password of 40 characters!', '' ]) {
	let h = r.hide_password(pw, 'testing123', auth);
	ok(length(h) % 16 == 0 && length(h) >= 16, `hidden length for "${pw}"`);
	eq(r.unhide_password(h, 'testing123', auth), pw, `password round trip "${pw}"`);
}

// Attribute codec, incl. VSAs and IPv6.
let bin = r.encode_attrs([
	[ 'User-Name', 'alice' ], [ 'Session-Timeout', 3600 ], [ 'Framed-IP-Address', '10.0.0.7' ],
	[ 'Framed-IPv6-Address', '2001:db8::7' ], [ 'Framed-IPv6-Prefix', '2001:db8:1::/48' ],
	[ 'Mikrotik-Rate-Limit', '2M/4M' ], [ 'Mikrotik-Xmit-Limit', 100000 ], [ 'WISPr-Location-Name', 'Lobby' ],
	[ 'Class', null ],
]);
let attrs = r.decode_attrs(bin);
let pkt = { attrs };
eq(r.attr(pkt, 'User-Name'), 'alice', 'string');
eq(r.attr(pkt, 'Session-Timeout'), 3600, 'integer');
eq(r.attr(pkt, 'Framed-IP-Address'), '10.0.0.7', 'ipaddr');
eq(r.attr(pkt, 'Framed-IPv6-Address'), '2001:db8::7', 'ipv6addr');
eq(r.attr(pkt, 'Framed-IPv6-Prefix'), '2001:db8:1::/48', 'ipv6prefix');
eq(r.attr(pkt, 'Mikrotik-Rate-Limit'), '2M/4M', 'mikrotik vsa');
eq(r.attr(pkt, 'Mikrotik-Xmit-Limit'), 100000, 'mikrotik int vsa');
eq(r.attr(pkt, 'WISPr-Location-Name'), 'Lobby', 'wispr vsa');
eq(length(attrs), 8, 'null values skipped');

// Access-Request carries a valid Message-Authenticator.
let req = r.access_request(7, [ [ 'User-Name', 'bob' ], [ 'User-Password', 'pw' ] ], 'testing123');
let p = r.parse(req.packet);
eq(p.code, 1, 'access-request code');
eq(r.unhide_password(r.attr(p, 'User-Password'), 'testing123', p.auth), 'pw', 'password recoverable by server');
ok(length(r.attr(p, 'Message-Authenticator')) == 16, 'message-authenticator present');

// Response signed by "server" verifies; tampering or wrong secret does not.
let resp = r.parse(r.response(r.CODE.ACCESS_ACCEPT, 7, req.auth, [ [ 'Session-Timeout', 60 ] ], 'testing123'));
ok(r.verify_response(resp, req.auth, 'testing123', true), 'response verifies');
ok(!r.verify_response(resp, req.auth, 'wrong', true), 'wrong secret rejected');
let bad = r.parse(r.response(r.CODE.ACCESS_ACCEPT, 7, req.auth, [ [ 'Session-Timeout', 60 ] ], 'testing123'));
bad.raw = substr(bad.raw, 0, length(bad.raw) - 1) + chr(ord(bad.raw, length(bad.raw) - 1) ^ 1);
ok(!r.verify_response(bad, req.auth, 'testing123', true), 'tampered response rejected');

// Accounting / CoA request signatures.
let acct = r.parse(r.signed_request(r.CODE.ACCOUNTING_REQUEST, 9, [ [ 'Acct-Status-Type', 1 ] ], 's3cret', false).packet);
ok(r.verify_signed_request(acct, 's3cret', false), 'accounting request verifies');
let coa = r.parse(r.signed_request(r.CODE.DISCONNECT_REQUEST, 3, [ [ 'User-Name', 'x' ] ], 's3cret', true).packet);
ok(r.verify_signed_request(coa, 's3cret', true), 'disconnect request with MA verifies');
let coa_noma = r.parse(r.signed_request(r.CODE.DISCONNECT_REQUEST, 3, [ [ 'User-Name', 'x' ] ], 's3cret', false).packet);
ok(!r.verify_signed_request(coa_noma, 's3cret', true), 'missing MA rejected when required');

// Gigawords, MAC format, ISO 8601.
eq(r.split64(5368709121), [ 1073741825, 1 ], 'split64');
eq(r.join64(1073741825, 1), 5368709121, 'join64');
eq(r.format_mac('02:00:0a:bb:cc:dd', 'XX-XX-XX-XX-XX-XX'), '02-00-0A-BB-CC-DD', 'mac format dash');
eq(r.format_mac('02:00:0a:bb:cc:dd', 'xxxx.xxxx.xxxx'), '0200.0abb.ccdd', 'mac format cisco');
eq(r.parse_iso8601('2026-10-18T20:00:00Z'), 1792353600, 'iso8601 utc');
eq(r.parse_iso8601('2026-10-18T20:00:00+05:00'), 1792335600, 'iso8601 offset');
eq(r.parse_iso8601('garbage'), null, 'iso8601 garbage');

done();
