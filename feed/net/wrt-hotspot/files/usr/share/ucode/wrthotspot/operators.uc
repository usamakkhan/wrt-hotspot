// Operator (staff) accounts for the operator panel: rpcd login sections in
// /etc/config/rpcd, so logins go through rpcd's normal session handling and
// permissions are plain rpcd ACL groups:
//   operator - users, vouchers, sessions, history, reports
//   admin    - the same plus operator management
// Only sections we created (option wrthotspot_role) are ever touched.
'use strict';

import { cursor } from 'uci';
import { md5 } from 'digest';
import { random_bytes } from 'wrthotspot.util';

export const ROLES = {
	operator: [ 'wrthotspot-operator' ],
	admin: [ 'wrthotspot-operator', 'wrthotspot-admin' ],
};

const ITOA64 = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

function bin_md5(s) {
	return hexdec(md5(s));
}

function to64(v, n) {
	let out = '';

	while (n-- > 0) {
		out += substr(ITOA64, v & 0x3f, 1);
		v >>= 6;
	}

	return out;
}

// FreeBSD/Linux MD5-crypt ($1$), as checked by rpcd through crypt(3).
export function md5crypt(pw, salt) {
	salt = substr(salt ?? '', 0, 8);

	let magic = '$1$';
	let fin = bin_md5(pw + salt + pw);
	let ctx = pw + magic + salt;

	for (let pl = length(pw); pl > 0; pl -= 16)
		ctx += substr(fin, 0, min(pl, 16));

	for (let i = length(pw); i; i >>= 1)
		ctx += (i & 1) ? '\0' : substr(pw, 0, 1);

	fin = bin_md5(ctx);

	for (let i = 0; i < 1000; i++) {
		let c = (i & 1) ? pw : fin;

		if (i % 3)
			c += salt;

		if (i % 7)
			c += pw;

		c += (i & 1) ? fin : pw;
		fin = bin_md5(c);
	}

	let b = (i) => ord(fin, i);
	let out = '';

	out += to64((b(0) << 16) | (b(6) << 8) | b(12), 4);
	out += to64((b(1) << 16) | (b(7) << 8) | b(13), 4);
	out += to64((b(2) << 16) | (b(8) << 8) | b(14), 4);
	out += to64((b(3) << 16) | (b(9) << 8) | b(15), 4);
	out += to64((b(4) << 16) | (b(10) << 8) | b(5), 4);
	out += to64(b(11), 2);

	return `${magic}${salt}$${out}`;
};

function new_salt() {
	let raw = random_bytes(8), s = '';

	for (let i = 0; i < 8; i++)
		s += substr(ITOA64, ord(raw, i) & 0x3f, 1);

	return s;
}

export function valid_username(u) {
	return type(u) == 'string' && !!match(u, /^[A-Za-z0-9_.-]{2,32}$/) && u != 'root';
};

function section_of(c, username) {
	let sid = null;

	c.foreach('rpcd', 'login', (s) => {
		if (s.username == username)
			sid = s['.name'];
	});

	return sid;
}

export function list() {
	let c = cursor();
	let out = [];

	c.load('rpcd');
	c.foreach('rpcd', 'login', (s) => {
		if (s.wrthotspot_role)
			push(out, { username: s.username, role: s.wrthotspot_role, comment: s.wrthotspot_comment ?? '' });
	});

	return out;
};

// Create or update; password null keeps the current one. -> error or null
export function set(username, password, role, comment) {
	if (!valid_username(username))
		return 'invalid username (2-32 of A-Z a-z 0-9 . _ -, not root)';

	if (!ROLES[role])
		return 'role must be operator or admin';

	let c = cursor();
	c.load('rpcd');

	let sid = section_of(c, username);

	if (sid && !c.get('rpcd', sid, 'wrthotspot_role'))
		return 'this login is not a hotspot operator and cannot be changed here';

	if (!sid && (password == null || length(password) < 6))
		return 'a password of at least 6 characters is required';

	if (password != null && password !== '' && length(password) < 6)
		return 'the password needs at least 6 characters';

	sid ??= c.add('rpcd', 'login');

	c.set('rpcd', sid, 'username', username);
	c.set('rpcd', sid, 'wrthotspot_role', role);
	c.set('rpcd', sid, 'wrthotspot_comment', comment ?? '');
	c.set('rpcd', sid, 'read', ROLES[role]);
	c.set('rpcd', sid, 'write', ROLES[role]);

	if (password != null && password !== '')
		c.set('rpcd', sid, 'password', md5crypt(password, new_salt()));

	c.save('rpcd');
	c.commit('rpcd');
	return null;
};

export function remove(username) {
	let c = cursor();
	c.load('rpcd');

	let sid = section_of(c, username);

	if (!sid || !c.get('rpcd', sid, 'wrthotspot_role'))
		return 'no such operator';

	c.delete('rpcd', sid);
	c.save('rpcd');
	c.commit('rpcd');
	return null;
};
