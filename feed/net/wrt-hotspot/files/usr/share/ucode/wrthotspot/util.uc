// Small helpers shared by hotspotd, the portal handler and the CLI.
'use strict';

import * as fs from 'fs';

const LEVELS = { error: 0, warn: 1, info: 2, debug: 3 };
let log_level = LEVELS.info;

export function set_log_level(name) {
	log_level = LEVELS[name] ?? LEVELS.info;
};

// procd forwards stderr to syslog, so plain warn() is the log sink.
export function log(level, fmt, ...args) {
	if ((LEVELS[level] ?? 0) > log_level)
		return;

	warn(sprintf(`[${level}] ${fmt}\n`, ...args));
};

// MikroTik-style durations: "1w2d3h4m5s", "30m", "00:05:00", plain seconds,
// "none"/""/"0" -> 0 (meaning unlimited / disabled).
export function parse_duration(v) {
	if (v == null || v === '' || v === 'none' || v === false)
		return 0;

	if (type(v) == 'int' || type(v) == 'double')
		return int(v);

	v = lc(trim(`${v}`));

	let m = match(v, /^(\d+):(\d{1,2}):(\d{1,2})$/);
	if (m)
		return int(m[1]) * 3600 + int(m[2]) * 60 + int(m[3]);

	if (match(v, /^\d+$/))
		return int(v);

	const unit = { w: 604800, d: 86400, h: 3600, m: 60, s: 1 };
	let total = 0, rest = v;

	while (length(rest)) {
		m = match(rest, /^(\d+)([wdhms])(.*)$/);
		if (!m)
			return null;

		total += int(m[1]) * unit[m[2]];
		rest = m[3];
	}

	return total;
};

export function fmt_duration(secs) {
	secs = int(secs ?? 0);

	if (secs <= 0)
		return '0s';

	let out = '';
	for (let u in [ [ 'w', 604800 ], [ 'd', 86400 ], [ 'h', 3600 ], [ 'm', 60 ], [ 's', 1 ] ]) {
		if (secs >= u[1]) {
			out += `${int(secs / u[1])}${u[0]}`;
			secs %= u[1];
		}
	}

	return out;
};

// Byte sizes: "500", "10k", "20M", "1.5G" (binary multiples). 0/"" -> 0 (unlimited).
export function parse_size(v) {
	if (v == null || v === '' || v === 'none')
		return 0;

	if (type(v) == 'int' || type(v) == 'double')
		return int(v);

	let m = match(lc(trim(`${v}`)), /^([0-9]+(\.[0-9]+)?)([kmgt]?)i?b?$/);
	if (!m)
		return null;

	const mul = { '': 1, k: 1024, m: 1048576, g: 1073741824, t: 1099511627776 };
	return int(+m[1] * mul[m[3]]);
};

export function fmt_bytes(n) {
	n = +(n ?? 0);

	for (let u in [ [ 'GiB', 1073741824 ], [ 'MiB', 1048576 ], [ 'KiB', 1024 ] ])
		if (n >= u[1])
			return sprintf('%.1f %s', n / u[1], u[0]);

	return `${int(n)} B`;
};

export function normalize_mac(mac) {
	if (type(mac) != 'string')
		return null;

	mac = lc(replace(trim(mac), /-/g, ':'));

	if (match(mac, /^[0-9a-f]{12}$/))
		mac = join(':', map(match(mac, /../g), (m) => m[0]));

	return match(mac, /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/) ? mac : null;
};

// uhttpd listens dual-stack, so IPv4 clients may show up as ::ffff:a.b.c.d.
export function normalize_ip(ip) {
	if (type(ip) != 'string')
		return null;

	ip = lc(trim(ip));

	let m = match(ip, /^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
	if (m)
		return m[1];

	let i = index(ip, '%');
	return (i >= 0) ? substr(ip, 0, i) : ip;
};

export function ip_family(ip) {
	return (index(ip ?? '', ':') >= 0) ? 6 : 4;
};

export function random_bytes(n) {
	let f = fs.open('/dev/urandom', 'r');
	let b = f.read(n);
	f.close();
	return b;
};

export function random_hex(n) {
	return hexenc(random_bytes(n));
};

// Write a file atomically (tmp + rename) so a power cut never leaves half a DB.
export function write_atomic(path, data) {
	let tmp = `${path}.tmp`;

	if (!fs.writefile(tmp, data))
		return false;

	return fs.rename(tmp, path);
};

export function read_json(path) {
	let s = fs.readfile(path);

	if (s == null)
		return null;

	try {
		return json(s);
	}
	catch (e) {
		log('error', 'Corrupt JSON in %s: %s', path, e);
		return null;
	}
};

export function mkdir_p(path) {
	let cur = '';

	for (let part in split(path, '/')) {
		if (part == '')
			continue;

		cur += '/' + part;

		if (!fs.stat(cur))
			fs.mkdir(cur, 0o755);
	}
};

// Run a command, return { code, out } with stderr folded into out.
export function run(cmd) {
	let p = fs.popen(`${cmd} 2>&1`, 'r');

	if (!p)
		return { code: -1, out: fs.error() };

	let out = p.read('all');
	let code = p.close();

	return { code, out };
};

export function shell_quote(s) {
	// A function replacement, because ucode interprets escapes in replacement strings.
	return "'" + replace(`${s}`, "'", () => "'\\''") + "'";
};

export function to_bool(v) {
	return v === true || v === 1 || v === '1' || v === 'yes' || v === 'on' || v === 'true' || v === 'enabled';
};

export function as_list(v) {
	if (v == null || v === '')
		return [];

	return (type(v) == 'array') ? v : split(`${v}`, /[ ,]+/);
};

export function now() {
	return time();
};
