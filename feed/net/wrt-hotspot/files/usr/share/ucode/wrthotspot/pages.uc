// Login page sets ("html_directory" of a server profile).
//
// Built-in sets live in /usr/share/wrthotspot/pages/<name>, uploaded ones in
// /etc/wrthotspot/pages/<name> (kept on sysupgrade). LuCI unpacks the zip in
// the browser (stock OpenWrt has no unzip) and sends the files here in
// base64 chunks: begin -> put... -> commit. Nothing reaches the live set
// before commit has checked the whole upload.
'use strict';

import * as fs from 'fs';
import { run, shell_quote } from 'wrthotspot.util';

export const BUILTIN_DIR = '/usr/share/wrthotspot/pages';
export const CUSTOM_DIR = '/etc/wrthotspot/pages';
const STAGE_DIR = '/tmp/wrthotspot-pages';
const STAGE_TTL = 600;

export const MAX_FILE = 512 * 1024;
export const MAX_TOTAL = 2 * 1024 * 1024;
export const MAX_FILES = 200;
export const CHUNK = 32 * 1024;

// What the portal serves (portal.uc MIME), nothing executable on the router.
export const EXTENSIONS = [ 'html', 'css', 'js', 'png', 'jpg', 'jpeg', 'gif', 'svg', 'ico', 'webp',
	'woff', 'woff2', 'json', 'txt' ];

export function valid_name(n) {
	return type(n) == 'string' && !!match(n, /^[A-Za-z0-9_-]{1,32}$/);
};

// Same rule as the portal's page_path(), plus: no hidden files, an allowed
// extension and at most 4 levels.
export function valid_path(p) {
	if (type(p) != 'string' || length(p) > 128 || !match(p, /^[A-Za-z0-9_.-]+(\/[A-Za-z0-9_.-]+)*$/))
		return false;

	let parts = split(p, '/');

	if (length(parts) > 4)
		return false;

	for (let s in parts)
		if (substr(s, 0, 1) == '.')
			return false;

	let ext = match(p, /\.([A-Za-z0-9]+)$/);
	return !!ext && (lc(ext[1]) in EXTENSIONS);
};

function walk(dir, prefix, out) {
	for (let e in (fs.lsdir(dir) ?? [])) {
		let st = fs.lstat(`${dir}/${e}`);
		let rel = prefix ? `${prefix}/${e}` : e;

		if (st?.type == 'directory')
			walk(`${dir}/${e}`, rel, out);
		else if (st?.type == 'file')
			push(out, { path: rel, size: st.size });
	}

	return out;
}

function files_in(dir) {
	return sort(walk(dir, '', []), (a, b) => (a.path < b.path) ? -1 : (a.path > b.path) ? 1 : 0);
}

function total(files) {
	let n = 0;

	for (let f in files)
		n += f.size;

	return n;
}

// name -> { dir, builtin }; uploaded sets cannot shadow built-in ones.
function find(name) {
	if (!valid_name(name))
		return null;

	if (fs.stat(`${BUILTIN_DIR}/${name}`)?.type == 'directory')
		return { dir: `${BUILTIN_DIR}/${name}`, builtin: true };

	if (fs.stat(`${CUSTOM_DIR}/${name}`)?.type == 'directory')
		return { dir: `${CUSTOM_DIR}/${name}`, builtin: false };

	return null;
}

function used_by(cfg, dir) {
	let out = [];

	for (let n, sp in cfg?.server_profiles ?? {})
		if (replace(sp.html_directory ?? '', /\/+$/, '') == dir)
			push(out, n);

	return out;
}

export function list(cfg) {
	let out = [];

	for (let base in [ BUILTIN_DIR, CUSTOM_DIR ]) {
		for (let name in sort(fs.lsdir(base) ?? [])) {
			let dir = `${base}/${name}`;

			if (!valid_name(name) || fs.lstat(dir)?.type != 'directory')
				continue;

			// (an upload named like a built-in set is hidden by it)
			if (base == CUSTOM_DIR && fs.stat(`${BUILTIN_DIR}/${name}`))
				continue;

			let f = files_in(dir);
			push(out, {
				name, dir, builtin: base == BUILTIN_DIR, files: length(f), size: total(f),
				login: !!fs.stat(`${dir}/login.html`), used_by: used_by(cfg, dir),
			});
		}
	}

	return out;
};

export function files(name) {
	let s = find(name);
	return s ? [ files_in(s.dir), null ] : [ null, 'no such page set' ];
};

// One chunk of a file, base64 (ubus carries JSON strings, not bytes).
export function read(name, path, offset) {
	let s = find(name);

	if (!s)
		return [ null, 'no such page set' ];

	if (!valid_path(path))
		return [ null, 'invalid file name' ];

	let p = `${s.dir}/${path}`;
	let st = fs.lstat(p);

	if (st?.type != 'file')
		return [ null, 'no such file' ];

	offset = max(0, int(offset ?? 0));

	let f = fs.open(p, 'r');

	if (!f)
		return [ null, 'cannot read the file' ];

	f.seek(offset);
	let data = f.read(CHUNK) ?? '';
	f.close();

	return [ { data: b64enc(data), size: st.size, eof: offset + length(data) >= st.size }, null ];
};

function stage(name) {
	return `${STAGE_DIR}/${name}`;
}

function mkdirs(path) {
	let cur = '';

	for (let s in split(path, '/')) {
		if (s == '')
			continue;

		cur += `/${s}`;

		if (!fs.stat(cur) && !fs.mkdir(cur, 0755))
			return false;
	}

	return true;
}

export function begin(name) {
	if (!valid_name(name))
		return 'invalid name: use 1-32 letters, digits, "-" or "_"';

	if (fs.stat(`${BUILTIN_DIR}/${name}`))
		return `"${name}" is a built-in page set: choose another name`;

	run(`rm -rf ${shell_quote(stage(name))}`);

	// Abandoned uploads (browser closed mid-way) would hold RAM in /tmp until
	// a reboot: drop any that saw no chunk for 10 minutes.
	for (let e in (fs.lsdir(STAGE_DIR) ?? []))
		if (valid_name(e) && (fs.stat(`${STAGE_DIR}/${e}`)?.mtime ?? 0) < time() - STAGE_TTL)
			run(`rm -rf ${shell_quote(stage(e))}`);

	return mkdirs(stage(name)) ? null : 'cannot create the upload area';
};

// offset = where this chunk goes; 0 starts the file. Chunks arrive in order.
export function put(name, path, data, offset) {
	if (!valid_name(name) || fs.stat(stage(name))?.type != 'directory')
		return 'no upload in progress for this name';

	if (!valid_path(path))
		return `file not allowed: ${path}`;

	let bytes = b64dec(data ?? '');

	if (bytes == null)
		return 'invalid data';

	let p = `${stage(name)}/${path}`;
	let have = fs.stat(p)?.size ?? 0;

	offset = int(offset ?? 0);

	if (offset != 0 && offset != have)
		return `${path}: chunk out of order`;

	if (offset + length(bytes) > MAX_FILE)
		return `${path}: larger than ${MAX_FILE / 1024} KiB`;

	let staged = files_in(stage(name));

	if (offset == 0 && !fs.stat(p) && length(staged) >= MAX_FILES)
		return `more than ${MAX_FILES} files`;

	if (total(staged) - (offset == 0 ? have : 0) + length(bytes) > MAX_TOTAL)
		return `page set larger than ${MAX_TOTAL / 1048576} MiB`;

	let dir = match(p, /^(.*)\/[^\/]+$/)[1];

	if (!mkdirs(dir))
		return 'cannot create directory';

	let f = fs.open(p, offset == 0 ? 'w' : 'a');

	if (!f)
		return 'cannot write the file';

	f.write(bytes);
	f.close();
	return null;
};

function free_kib(path) {
	let m = match(run(`df -k ${shell_quote(path)}`).out ?? '', /\n[^\n]*[ \t]+[0-9]+[ \t]+[0-9]+[ \t]+([0-9]+)[ \t]+[0-9]+%/);
	return m ? int(m[1]) : null;
}

export function commit(name) {
	if (!valid_name(name) || fs.stat(stage(name))?.type != 'directory')
		return [ null, 'no upload in progress for this name' ];

	let f = files_in(stage(name));
	let size = total(f);
	let abort = (msg) => { run(`rm -rf ${shell_quote(stage(name))}`); return [ null, msg ]; };

	if (!fs.stat(`${stage(name)}/login.html`))
		return abort('the page set has no login.html at its top level');

	mkdirs(CUSTOM_DIR);

	let free = free_kib(CUSTOM_DIR);

	// Keep some room on the overlay: a full flash breaks config saves.
	if (free != null && size / 1024 + 256 > free)
		return abort(`not enough flash: ${free} KiB free, the page set needs ${int(size / 1024) + 1} KiB`);

	let dest = `${CUSTOM_DIR}/${name}`;
	let q = shell_quote;
	let r = run(`rm -rf ${q(dest + '.new')} && cp -R ${q(stage(name))} ${q(dest + '.new')} && ` +
		`rm -rf ${q(dest)} && mv ${q(dest + '.new')} ${q(dest)}`);

	run(`rm -rf ${q(stage(name))} ${q(dest + '.new')}`);

	if (r.code != 0)
		return [ null, `cannot install: ${trim(r.out)}` ];

	return [ { name, dir: dest, files: length(f), size }, null ];
};

export function remove(name, cfg) {
	let s = find(name);

	if (!s)
		return 'no such page set';

	if (s.builtin)
		return 'built-in page sets cannot be removed';

	let u = used_by(cfg, s.dir);

	if (length(u))
		return `in use by server profile ${join(', ', u)}`;

	let r = run(`rm -rf ${shell_quote(s.dir)}`);
	return (r.code == 0) ? null : trim(r.out);
};
