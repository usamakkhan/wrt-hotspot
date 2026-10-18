// Local user database (MikroTik /ip hotspot user), kept as JSON on flash.
//
// Users can number in the thousands (vouchers), which is why they live here
// rather than in UCI. Usage counters change constantly, so writes are
// debounced: admin edits flush at once, usage flushes every db_sync_interval.
'use strict';

import * as fs from 'fs';
import { read_json, write_atomic, mkdir_p, normalize_mac, parse_duration, parse_size, log } from 'wrthotspot.util';

const FIELDS = {
	password: 'string', profile: 'string', server: 'string', mac: 'mac',
	limit_uptime: 'duration', limit_bytes_in: 'size', limit_bytes_out: 'size', limit_bytes_total: 'size',
	disabled: 'bool', comment: 'string', email: 'string',
};

function coerce(kind, v) {
	switch (kind) {
	case 'string': return (v == null) ? '' : `${v}`;
	case 'bool': return v === true || v === 1 || v === '1' || v === 'yes' || v === 'true';
	case 'mac': return (v == null || v === '' || v === '00:00:00:00:00:00') ? '' : normalize_mac(v);
	case 'duration': return parse_duration(v);
	case 'size': return parse_size(v);
	}
}

export function valid_name(name) {
	return type(name) == 'string' && length(name) > 0 && length(name) <= 64 && !match(name, /[[:cntrl:]]/);
};

export function create(db_dir) {
	let path = `${db_dir}/users.json`;
	let users = {};
	let dirty = false;
	let db;

	db = {
		load: function() {
			mkdir_p(db_dir);

			let data = read_json(path);
			users = data?.users ?? {};

			if (data == null && fs.stat(path))
				log('error', 'User DB %s unreadable, starting empty (file kept)', path);

			return length(keys(users));
		},

		save: function(force) {
			if (!dirty && !force)
				return true;

			// Passwords are stored in clear (CHAP needs them): root-only file.
			if (!write_atomic(path, sprintf('%J', { version: 1, users }), 0o600)) {
				log('error', 'Cannot write %s: %s', path, fs.error());
				return false;
			}

			dirty = false;
			return true;
		},

		mark_dirty: function() { dirty = true; },

		get: function(name) { return users[name]; },

		list: function() {
			return map(sort(keys(users)), (n) => users[n]);
		},

		count: function() { return length(keys(users)); },

		// Create or update; returns [ user, error ].
		set: function(name, attrs) {
			if (!valid_name(name))
				return [ null, 'invalid user name' ];

			let u = users[name] ?? {
				name, password: '', profile: 'default', server: 'all', mac: '',
				limit_uptime: 0, limit_bytes_in: 0, limit_bytes_out: 0, limit_bytes_total: 0,
				disabled: false, comment: '', email: '',
				used: { uptime: 0, bytes_in: 0, bytes_out: 0 },
			};

			for (let k, kind in FIELDS) {
				if (!exists(attrs, k))
					continue;

				let v = coerce(kind, attrs[k]);

				if (v == null)
					return [ null, `invalid value for ${k}` ];

				u[k] = v;
			}

			users[name] = u;
			dirty = true;
			db.save(true);

			return [ u, null ];
		},

		remove: function(name) {
			if (!users[name])
				return false;

			delete users[name];
			dirty = true;
			db.save(true);
			return true;
		},

		reset_counters: function(name) {
			let u = users[name];

			if (!u)
				return false;

			u.used = { uptime: 0, bytes_in: 0, bytes_out: 0 };
			delete u.periods;
			dirty = true;
			db.save(true);
			return true;
		},

		// Usage within a limitation's current quota period (start = period
		// start); a newer period starts from zero.
		period_used: function(name, lim, start) {
			let p = users[name]?.periods?.[lim];
			return (p && p.start == start) ? p : { start, uptime: 0, bytes_in: 0, bytes_out: 0 };
		},

		add_period_usage: function(name, lim, start, uptime, bytes_in, bytes_out) {
			let u = users[name];

			if (!u)
				return;

			u.periods ??= {};

			let p = u.periods[lim];
			if (!p || p.start != start)
				p = u.periods[lim] = { start, uptime: 0, bytes_in: 0, bytes_out: 0 };

			p.uptime += uptime;
			p.bytes_in += bytes_in;
			p.bytes_out += bytes_out;
			dirty = true;
		},

		add_usage: function(name, uptime, bytes_in, bytes_out) {
			let u = users[name];

			if (!u)
				return;

			u.used ??= { uptime: 0, bytes_in: 0, bytes_out: 0 };
			u.used.uptime += uptime;
			u.used.bytes_in += bytes_in;
			u.used.bytes_out += bytes_out;
			dirty = true;
		},
	};

	return db;
};

// Strip the password before handing a user to callers that display it.
export function public_view(u) {
	if (!u)
		return null;

	let v = { ...u };
	delete v.password;
	return v;
};
