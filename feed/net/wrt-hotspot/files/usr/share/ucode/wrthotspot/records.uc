// Session history and voucher sales, plus the reports built on them.
// Kept in RAM and written to flash with the user DB (db_sync_interval), as
// one bounded JSON file so a small router's flash isn't worn or filled.
'use strict';

import * as fs from 'fs';
import { read_json, write_atomic, log } from 'wrthotspot.util';

function day_key(t) {
	let l = localtime(t);
	return sprintf('%04d-%02d-%02d', l.year, l.mon, l.mday);
}

function hour_key(t) {
	let l = localtime(t);
	return sprintf('%04d-%02d-%02d %02d:00', l.year, l.mon, l.mday, l.hour);
}

// "5", "5.50", "5 USD", "$5" -> 5.5 ; anything else -> 0
export function price_value(p) {
	let m = match(`${p ?? ''}`, /([0-9]+(\.[0-9]+)?)/);
	return m ? +m[1] : 0;
};

export function create(db_dir, max_entries) {
	let path = `${db_dir}/history.json`;
	let history = [];	// oldest first
	let sales = [];
	let dirty = false;
	let self;

	function trim_list(l) {
		while (length(l) > max_entries)
			shift(l);
	}

	self = {
		load: function() {
			let d = read_json(path);
			history = d?.history ?? [];
			sales = d?.sales ?? [];
			return length(history);
		},

		save: function(force) {
			if (!dirty && !force)
				return;

			write_atomic(path, sprintf('%J', { version: 1, history, sales }), 0o600);
			dirty = false;
		},

		add_session: function(e) {
			push(history, e);
			trim_list(history);
			dirty = true;
		},

		// First use of a voucher: that's when it counts as sold.
		add_sale: function(e) {
			push(sales, e);
			trim_list(sales);
			dirty = true;
		},

		// filter: { from, to, user, mac, limit } -> newest first
		query: function(f) {
			let out = [];
			let q = lc(f?.search ?? '');

			for (let i = length(history) - 1; i >= 0 && length(out) < (f?.limit || 500); i--) {
				let e = history[i];

				if ((f?.from && e.end < f.from) || (f?.to && e.start >= f.to))
					continue;

				if (q && index(lc(`${e.user} ${e.mac} ${e.ipv4 ?? ''} ${e.batch ?? ''}`), q) < 0)
					continue;

				push(out, e);
			}

			return out;
		},

		// group: day | hour | user | server | profile | login_by | batch
		report: function(from, to, group) {
			let key = {
				day: (e, t) => day_key(t), hour: (e, t) => hour_key(t),
				user: (e) => e.user, server: (e) => e.server, profile: (e) => e.profile,
				login_by: (e) => e.login_by, batch: (e) => e.batch || '-',
			}[group] ?? ((e, t) => day_key(t));

			let rows = {};
			let total = { sessions: 0, uptime: 0, bytes_in: 0, bytes_out: 0, activations: 0, revenue: 0 };
			let tu = {}, td = {};

			function row(k) {
				return (rows[k] ??= { key: k, sessions: 0, uptime: 0, bytes_in: 0, bytes_out: 0, activations: 0, revenue: 0, _u: {}, _d: {} });
			}

			for (let e in history) {
				if (e.start < from || e.start >= to)
					continue;

				let r = row(key(e, e.start));
				r.sessions++;
				r.uptime += e.uptime;
				r.bytes_in += e.bytes_in;
				r.bytes_out += e.bytes_out;
				r._u[e.user] = true;
				r._d[e.mac] = true;

				total.sessions++;
				total.uptime += e.uptime;
				total.bytes_in += e.bytes_in;
				total.bytes_out += e.bytes_out;
				tu[e.user] = true;
				td[e.mac] = true;
			}

			for (let s in sales) {
				if (s.time < from || s.time >= to)
					continue;

				let r = row(key(s, s.time));
				r.activations++;
				r.revenue += price_value(s.price);
				total.activations++;
				total.revenue += price_value(s.price);
			}

			let list = map(sort(keys(rows)), (k) => {
				let r = rows[k];
				r.users = length(keys(r._u));
				r.devices = length(keys(r._d));
				delete r._u;
				delete r._d;
				return r;
			});

			total.users = length(keys(tu));
			total.devices = length(keys(td));

			return { from, to, group, total, rows: list };
		},
	};

	return self;
};
