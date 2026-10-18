// Voucher batches (MikroTik User Manager "add-batch-users" / vouchers).
// A voucher is an ordinary local user with batch, price and validity, so
// every login method, limit and report works for it unchanged.
'use strict';

import { random_bytes, parse_duration, parse_size } from 'wrthotspot.util';

// Alphabets without look-alikes (0/O, 1/l/I) for codes typed from paper.
export const CHARSETS = {
	digits: '0123456789',
	lower: 'abcdefghjkmnpqrstuvwxyz',
	upper: 'ABCDEFGHJKLMNPQRSTUVWXYZ',
	alnum: 'abcdefghjkmnpqrstuvwxyz23456789',
	mixed: 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789',
};

// Uniform random code (rejection sampling, no modulo bias).
export function code(len, charset) {
	let cs = CHARSETS[charset] ?? CHARSETS.alnum;
	let n = length(cs), limit = 256 - (256 % n);
	let out = '';

	while (length(out) < len) {
		let raw = random_bytes(len * 2);

		for (let i = 0; i < length(raw) && length(out) < len; i++) {
			let b = ord(raw, i);
			if (b < limit)
				out += substr(cs, b % n, 1);
		}
	}

	return out;
};

function batch_id() {
	let t = localtime();
	return sprintf('B%04d%02d%02d-%s', t.year, t.mon, t.mday, code(4, 'alnum'));
}

// opts: { profile, count, prefix, length, charset, password: 'same'|'separate',
//         password_length, validity, limit_uptime, limit_bytes_total, limit_bytes_in,
//         limit_bytes_out, price, comment, server }
// -> [ { batch, vouchers: [ { name, password } ] }, error ]
export function create(users, opts, operator, profiles) {
	let count = int(opts.count ?? 0);
	let len = int(opts.length ?? 6);
	let plen = int(opts.password_length ?? len);
	let prefix = opts.prefix ?? '';
	let charset = opts.charset ?? 'alnum';

	if (count < 1 || count > 1000)
		return [ null, 'count must be 1-1000' ];

	if (len < 4 || len > 16 || plen < 4 || plen > 16)
		return [ null, 'code length must be 4-16' ];

	if (!CHARSETS[charset])
		return [ null, 'unknown character set' ];

	if (!match(prefix, /^[A-Za-z0-9_-]{0,8}$/))
		return [ null, 'prefix: up to 8 of A-Z a-z 0-9 _ -' ];

	if (opts.profile && profiles && !(opts.profile in profiles))
		return [ null, `unknown user profile ${opts.profile}` ];

	for (let k in [ 'validity', 'limit_uptime' ])
		if (opts[k] && parse_duration(opts[k]) == null)
			return [ null, `invalid ${k}` ];

	for (let k in [ 'limit_bytes_total', 'limit_bytes_in', 'limit_bytes_out' ])
		if (opts[k] && parse_size(opts[k]) == null)
			return [ null, `invalid ${k}` ];

	// Refuse batches that would need many retries to find free codes.
	let space = 1, need = (count + users.count()) * 20;
	for (let i = 0; i < len && space < need; i++)
		space *= length(CHARSETS[charset]);

	if (space < need)
		return [ null, 'code space too small for this many vouchers: use longer codes' ];

	let batch = batch_id();
	let now = time();
	let made = [];

	for (let i = 0; i < count; i++) {
		let name = null;

		for (let tries = 0; tries < 50 && !name; tries++) {
			let c = prefix + code(len, charset);
			if (!users.exists(c))
				name = c;
		}

		if (!name)
			return [ null, 'could not find free voucher codes' ];

		let password = (opts.password == 'separate') ? code(plen, charset) : name;

		let res = users.set(name, {
			password,
			profile: opts.profile || 'default',
			server: opts.server || 'all',
			validity: opts.validity ?? '',
			limit_uptime: opts.limit_uptime ?? '',
			limit_bytes_total: opts.limit_bytes_total ?? '',
			limit_bytes_in: opts.limit_bytes_in ?? '',
			limit_bytes_out: opts.limit_bytes_out ?? '',
			price: opts.price ?? '',
			batch,
			comment: opts.comment ?? '',
		}, true);

		if (!res[0])
			return [ null, res[1] ];

		users.set_internal(name, { created: now, created_by: operator ?? '' });
		push(made, { name, password });
	}

	users.save(true);
	return [ { batch, vouchers: made }, null ];
};

function is_used(u) {
	return !!(u.first_login || u.used?.uptime || u.used?.bytes_in || u.used?.bytes_out);
}

export function batches(users) {
	let by = {};

	for (let u in users.list()) {
		if (!u.batch)
			continue;

		let b = (by[u.batch] ??= {
			batch: u.batch, created: u.created ?? 0, created_by: u.created_by ?? '',
			profile: u.profile, price: u.price, validity: u.validity, comment: u.comment,
			count: 0, used: 0, expired: 0,
		});

		b.count++;

		if (is_used(u))
			b.used++;

		if (u.expires && u.expires <= time())
			b.expired++;
	}

	return sort(values(by), (a, b) => b.created - a.created);
};

// Codes and passwords of a batch, for printing.
export function list(users, batch) {
	return map(filter(users.list(), (u) => u.batch == batch), (u) => ({
		name: u.name, password: u.password, used: is_used(u), expires: u.expires ?? 0,
	}));
};

// Delete a batch's vouchers (by default only the unused ones). -> names
export function revoke(users, batch, all) {
	let names = map(filter(users.list(), (u) => u.batch == batch && (all || !is_used(u))), (u) => u.name);
	users.remove_many(names);
	return names;
};
