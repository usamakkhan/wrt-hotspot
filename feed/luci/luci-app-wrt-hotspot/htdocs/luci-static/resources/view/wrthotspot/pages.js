'use strict';
'require view';
'require ui';
'require uci';
'require rpc';
'require tools.wrthotspot as hs';

/*
 * Login page sets: list, download as zip, upload a zip, remove.
 *
 * Stock OpenWrt has no unzip, so the browser unpacks the zip and sends the
 * files to hotspotd in base64 chunks (pages_begin, pages_put..., pages_commit).
 * Downloads go the other way: pages_read chunks, zipped here (stored, no
 * compression: the sets are small).
 */

var callList = rpc.declare({ object: 'wrthotspot', method: 'pages_list' });
var callFiles = rpc.declare({ object: 'wrthotspot', method: 'pages_files', params: [ 'name' ] });
var callRead = rpc.declare({ object: 'wrthotspot', method: 'pages_read', params: [ 'name', 'path', 'offset' ] });
var callBegin = rpc.declare({ object: 'wrthotspot', method: 'pages_begin', params: [ 'name' ] });
var callPut = rpc.declare({ object: 'wrthotspot', method: 'pages_put', params: [ 'name', 'path', 'data', 'offset' ] });
var callCommit = rpc.declare({ object: 'wrthotspot', method: 'pages_commit', params: [ 'name' ] });
var callRemove = rpc.declare({ object: 'wrthotspot', method: 'pages_remove', params: [ 'name' ] });

var DOCS = 'https://github.com/usamakkhan/wrt-hotspot#custom-login-pages';
var SAMPLE = 'classic';

/* ---- bytes <-> base64 ---- */

function toBase64(u8) {
	var s = '';
	for (var i = 0; i < u8.length; i += 0x8000)
		s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
	return btoa(s);
}

function fromBase64(b64) {
	var s = atob(b64 || ''), u8 = new Uint8Array(s.length);
	for (var i = 0; i < s.length; i++)
		u8[i] = s.charCodeAt(i);
	return u8;
}

/* ---- zip ---- */

var CRC_TABLE = (function() {
	var t = new Uint32Array(256);
	for (var n = 0; n < 256; n++) {
		var c = n;
		for (var k = 0; k < 8; k++)
			c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
		t[n] = c >>> 0;
	}
	return t;
})();

function crc32(u8) {
	var c = 0xFFFFFFFF;
	for (var i = 0; i < u8.length; i++)
		c = CRC_TABLE[(c ^ u8[i]) & 0xFF] ^ (c >>> 8);
	return (c ^ 0xFFFFFFFF) >>> 0;
}

/* files: [ { path, data: Uint8Array } ] -> Blob (stored entries) */
function makeZip(files) {
	var enc = new TextEncoder(), parts = [], central = [], offset = 0;
	var d = new Date();
	var dosTime = (d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1);
	var dosDate = ((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate();

	files.forEach(function(f) {
		var name = enc.encode(f.path), crc = crc32(f.data), size = f.data.length;
		var lh = new DataView(new ArrayBuffer(30));
		lh.setUint32(0, 0x04034b50, true); lh.setUint16(4, 20, true); lh.setUint16(6, 0x0800, true);
		lh.setUint16(8, 0, true); lh.setUint16(10, dosTime, true); lh.setUint16(12, dosDate, true);
		lh.setUint32(14, crc, true); lh.setUint32(18, size, true); lh.setUint32(22, size, true);
		lh.setUint16(26, name.length, true); lh.setUint16(28, 0, true);

		var ch = new DataView(new ArrayBuffer(46));
		ch.setUint32(0, 0x02014b50, true); ch.setUint16(4, 20, true); ch.setUint16(6, 20, true);
		ch.setUint16(8, 0x0800, true); ch.setUint16(10, 0, true); ch.setUint16(12, dosTime, true);
		ch.setUint16(14, dosDate, true); ch.setUint32(16, crc, true); ch.setUint32(20, size, true);
		ch.setUint32(24, size, true); ch.setUint16(28, name.length, true);
		ch.setUint32(38, 0x81A4 << 16, true); ch.setUint32(42, offset, true);

		parts.push(lh.buffer, name, f.data);
		central.push(ch.buffer, name);
		offset += 30 + name.length + size;
	});

	var cdSize = central.reduce(function(n, p) { return n + (p.byteLength || p.length); }, 0);
	var end = new DataView(new ArrayBuffer(22));
	end.setUint32(0, 0x06054b50, true); end.setUint16(8, files.length, true); end.setUint16(10, files.length, true);
	end.setUint32(12, cdSize, true); end.setUint32(16, offset, true);

	return new Blob(parts.concat(central, [ end.buffer ]), { type: 'application/zip' });
}

function inflateRaw(u8) {
	if (typeof DecompressionStream != 'function')
		return Promise.reject(new Error(_('This browser cannot unpack compressed zip files. Use a current Chrome, Firefox, Edge or Safari, or zip with "store" (no compression).')));

	// (no `new Response(stream)`: luci.js replaces the global Response class)
	var reader = new Blob([ u8 ]).stream().pipeThrough(new DecompressionStream('deflate-raw')).getReader();
	var parts = [], size = 0;

	var pump = function() {
		return reader.read().then(function(r) {
			if (!r.done) {
				parts.push(r.value);
				size += r.value.length;
				return pump();
			}

			var out = new Uint8Array(size), o = 0;
			parts.forEach(function(p) { out.set(p, o); o += p.length; });
			return out;
		});
	};

	return pump();
}

/* ArrayBuffer -> Promise<[ { path, data } ]>; directories are left out. */
function readZip(buf) {
	var dv = new DataView(buf), u8 = new Uint8Array(buf), dec = new TextDecoder();
	var eocd = -1;

	for (var i = buf.byteLength - 22; i >= Math.max(0, buf.byteLength - 65557); i--)
		if (dv.getUint32(i, true) == 0x06054b50) { eocd = i; break; }

	if (eocd < 0)
		return Promise.reject(new Error(_('Not a zip file')));

	var count = dv.getUint16(eocd + 10, true), pos = dv.getUint32(eocd + 16, true);

	if (count == 0xFFFF || pos == 0xFFFFFFFF)
		return Promise.reject(new Error(_('ZIP64 archives are not supported')));

	var entries = [];

	for (var n = 0; n < count; n++) {
		if (pos + 46 > buf.byteLength || dv.getUint32(pos, true) != 0x02014b50)
			return Promise.reject(new Error(_('Damaged zip file')));

		var flags = dv.getUint16(pos + 8, true), method = dv.getUint16(pos + 10, true);
		var csize = dv.getUint32(pos + 20, true), usize = dv.getUint32(pos + 24, true);
		var nlen = dv.getUint16(pos + 28, true), xlen = dv.getUint16(pos + 30, true), clen = dv.getUint16(pos + 32, true);
		var lho = dv.getUint32(pos + 42, true);
		var name = dec.decode(u8.subarray(pos + 46, pos + 46 + nlen)).replace(/\\/g, '/');

		pos += 46 + nlen + xlen + clen;

		if (/\/$/.test(name))
			continue;

		if (flags & 1)
			return Promise.reject(new Error(_('Encrypted zip files are not supported')));

		if (method != 0 && method != 8)
			return Promise.reject(new Error(_('%s: unsupported compression method').format(name)));

		var start = lho + 30 + dv.getUint16(lho + 26, true) + dv.getUint16(lho + 28, true);
		entries.push({ path: name, method: method, raw: u8.subarray(start, start + csize), size: usize });
	}

	return Promise.all(entries.map(function(e) {
		return (e.method == 8 ? inflateRaw(e.raw) : Promise.resolve(e.raw)).then(function(data) {
			return { path: e.path, data: data };
		});
	}));
}

/* Junk from the zip tools, a single top folder ("hotspot/"), rules of the router. */
function prepare(files, info) {
	var skipped = [];

	files = files.filter(function(f) {
		var junk = /(^|\/)(__MACOSX|\.DS_Store|Thumbs\.db|desktop\.ini)(\/|$)/i.test(f.path);
		return !junk;
	});

	while (files.length && !files.some(function(f) { return f.path == 'login.html'; })) {
		var top = files[0].path.split('/')[0];

		if (files[0].path.indexOf('/') < 0 || !files.every(function(f) { return f.path.indexOf(top + '/') == 0; }))
			break;

		files.forEach(function(f) { f.path = f.path.substr(top.length + 1); });
	}

	var ok = files.filter(function(f) {
		var parts = f.path.split('/');
		var ext = (f.path.match(/\.([A-Za-z0-9]+)$/) || [])[1];
		var good = /^[A-Za-z0-9_.-]+(\/[A-Za-z0-9_.-]+)*$/.test(f.path) && f.path.length <= 128 && parts.length <= 4 &&
			parts.every(function(p) { return p.charAt(0) != '.'; }) &&
			ext && info.extensions.indexOf(ext.toLowerCase()) >= 0;

		if (good && f.data.length > info.limits.file) {
			skipped.push(_('%s (larger than %s)').format(f.path, '%1024.2mB'.format(info.limits.file)));
			return false;
		}

		if (!good)
			skipped.push(f.path);

		return good;
	});

	return { files: ok, skipped: skipped };
}

function saveBlob(blob, filename) {
	var a = E('a', { 'href': URL.createObjectURL(blob), 'download': filename, 'style': 'display:none' });
	document.body.appendChild(a);
	a.click();
	window.setTimeout(function() { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}

function failed(res) {
	return !res || res.ok === false;
}

return view.extend({
	load: function() {
		return Promise.all([ callList(), uci.load('wrthotspot') ]);
	},

	progress: function(title, text) {
		ui.showModal(title, [ E('p', { 'class': 'spinning', 'id': 'hs-pages-progress' }, text) ]);
	},

	step: function(text) {
		var p = document.getElementById('hs-pages-progress');
		if (p)
			p.textContent = text;
	},

	download: function(name) {
		this.progress(_('Download'), _('Reading %s…').format(name));

		return callFiles(name).then(L.bind(function(res) {
			if (failed(res))
				throw new Error(res ? res.error : _('No answer'));

			var out = [];

			var next = L.bind(function(i) {
				if (i >= res.files.length)
					return out;

				var path = res.files[i].path, chunks = [], total = 0;
				this.step(_('Reading %s (%d of %d)').format(path, i + 1, res.files.length));

				var more = function(offset) {
					return callRead(name, path, offset).then(function(r) {
						if (failed(r))
							throw new Error(path + ': ' + (r ? r.error : _('No answer')));

						var u8 = fromBase64(r.data);
						chunks.push(u8);
						total += u8.length;

						if (!r.eof && u8.length > 0)
							return more(offset + u8.length);

						var data = new Uint8Array(total), o = 0;
						chunks.forEach(function(c) { data.set(c, o); o += c.length; });
						out.push({ path: name + '/' + path, data: data });
					});
				};

				return more(0).then(function() { return next(i + 1); });
			}, this);

			return next(0);
		}, this)).then(function(files) {
			ui.hideModal();
			saveBlob(makeZip(files), 'wrthotspot-pages-' + name + '.zip');
		}).catch(function(e) {
			ui.hideModal();
			ui.addNotification(null, E('p', hs.h(e.message)), 'danger');
		});
	},

	upload: function(info, fileInput, nameInput) {
		var file = fileInput.files[0];
		var name = nameInput.value.trim();

		if (!file)
			return ui.addNotification(null, E('p', _('Choose a zip file')), 'warning');

		if (!/^[A-Za-z0-9_-]{1,32}$/.test(name))
			return ui.addNotification(null, E('p', _('Name: 1-32 letters, digits, "-" or "_"')), 'warning');

		if (info.pages.some(function(p) { return p.builtin && p.name == name; }))
			return ui.addNotification(null, E('p', _('"%s" is a built-in page set: choose another name').format(name)), 'warning');

		var exists = info.pages.some(function(p) { return p.name == name; });

		var go = L.bind(function() {
			this.progress(_('Upload'), _('Unpacking %s…').format(file.name));

			var prepared;

			return file.arrayBuffer().then(readZip).then(L.bind(function(files) {
				prepared = prepare(files, info);
				var f = prepared.files;

				if (!f.some(function(x) { return x.path == 'login.html'; }))
					throw new Error(_('The zip has no login.html (at the top or in a single folder).'));

				if (f.length > info.limits.files)
					throw new Error(_('More than %d files').format(info.limits.files));

				var size = f.reduce(function(n, x) { return n + x.data.length; }, 0);

				if (size > info.limits.total)
					throw new Error(_('The page set is larger than %s').format('%1024.2mB'.format(info.limits.total)));

				return callBegin(name);
			}, this)).then(L.bind(function(res) {
				if (failed(res))
					throw new Error(res ? res.error : _('No answer'));

				var f = prepared.files, chunk = info.limits.chunk;

				var put = L.bind(function(i, offset) {
					if (i >= f.length)
						return;

					var data = f[i].data;
					this.step(_('Uploading %s (%d of %d)').format(f[i].path, i + 1, f.length));

					return callPut(name, f[i].path, toBase64(data.subarray(offset, offset + chunk)), offset).then(function(r) {
						if (failed(r))
							throw new Error(r ? r.error : _('No answer'));

						return (offset + chunk < data.length) ? put(i, offset + chunk) : put(i + 1, 0);
					});
				}, this);

				return put(0, 0);
			}, this)).then(function() {
				return callCommit(name);
			}).then(L.bind(function(res) {
				if (failed(res))
					throw new Error(res ? res.error : _('No answer'));

				ui.hideModal();

				var msg = [ E('p', _('Page set "%s" installed: %d files, %s.').format(name, res.files, '%1024.2mB'.format(res.size))) ];

				if (prepared.skipped.length)
					msg.push(E('p', _('Left out (not allowed): %s').format(hs.h(prepared.skipped.join(', ')))));

				ui.addNotification(null, msg, prepared.skipped.length ? 'warning' : 'info');
				return this.refresh();
			}, this)).catch(function(e) {
				ui.hideModal();
				ui.addNotification(null, E('p', hs.h(e.message)), 'danger');
			});
		}, this);

		if (!exists)
			return go();

		ui.showModal(_('Replace page set?'), [
			E('p', _('A page set called "%s" exists. Replace it with this upload?').format(name)),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-negative', 'click': go }, _('Replace'))
			])
		]);
	},

	remove: function(p) {
		ui.showModal(_('Remove page set?'), [
			E('p', _('Remove the page set "%s"?').format(p.name)),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', {
					'class': 'btn cbi-button-negative',
					'click': ui.createHandlerFn(this, function() {
						return callRemove(p.name).then(L.bind(function(res) {
							ui.hideModal();
							if (failed(res))
								ui.addNotification(null, E('p', hs.h(res ? res.error : _('No answer'))), 'danger');
							return this.refresh();
						}, this));
					})
				}, _('Remove'))
			])
		]);
	},

	use: function(p) {
		// value: the uci section, label: the profile's name
		var profiles = uci.sections('wrthotspot', 'server_profile');
		var choices = {};
		profiles.forEach(function(s) { choices[s['.name']] = s.name || s['.name']; });
		var sel = new ui.Select(profiles.length ? profiles[0]['.name'] : null, choices, {});

		ui.showModal(_('Use "%s"').format(p.name), [
			E('p', _('Show these pages to the clients of a server profile:')),
			sel.render(),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', {
					'class': 'btn cbi-button-apply',
					'click': ui.createHandlerFn(this, function() {
						var prof = sel.getValue();
						if (!prof)
							return;
						uci.set('wrthotspot', prof, 'html_directory', p.dir);
						return uci.save().then(function() {
							ui.hideModal();
							return ui.changes.apply(true);
						});
					})
				}, _('Use'))
			])
		]);
	},

	rows: function(info) {
		return info.pages.map(L.bind(function(p) {
			return [
				E('strong', hs.h(p.name)),
				p.builtin ? _('built-in') : _('uploaded'),
				'%d / %s'.format(p.files, '%1024.2mB'.format(p.size)),
				p.used_by.length ? hs.h(p.used_by.join(', ')) : E('em', '-'),
				E('div', { 'class': 'nowrap' }, [
					E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'download', p.name) }, _('Download zip')), ' ',
					E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, 'use', p), 'disabled': p.login ? null : '' }, _('Use')), ' ',
					p.builtin ? '' : E('button', { 'class': 'btn cbi-button-negative', 'click': ui.createHandlerFn(this, 'remove', p), 'disabled': p.used_by.length ? '' : null }, _('Remove'))
				])
			];
		}, this));
	},

	refresh: function() {
		return Promise.all([ callList(), uci.load('wrthotspot') ]).then(L.bind(function(data) {
			this.info = data[0];
			cbi_update_table('#hs-pages', this.rows(this.info), E('em', _('No page sets')));
		}, this));
	},

	render: function(data) {
		this.info = data[0] || { pages: [], limits: {}, extensions: [] };

		var table = E('table', { 'class': 'table', 'id': 'hs-pages' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Name')), E('th', { 'class': 'th' }, _('Type')),
				E('th', { 'class': 'th' }, _('Files / size')), E('th', { 'class': 'th' }, _('Used by')), E('th', { 'class': 'th' }, '')
			])
		]);

		cbi_update_table(table, this.rows(this.info), E('em', _('hotspotd is not running')));

		var fileInput = E('input', { 'type': 'file', 'accept': '.zip,application/zip' });
		var nameInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': 'mypages', 'maxlength': 32 });

		fileInput.addEventListener('change', function() {
			var f = fileInput.files[0];
			if (f && !nameInput.value)
				nameInput.value = f.name.replace(/\.zip$/i, '').replace(/[^A-Za-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '').substr(0, 32);
		});

		var l = this.info.limits;

		return E('div', {}, [
			E('h2', _('Hotspot login pages')),
			E('p', [
				_('The pages hotspot users see. Download a set as a starting point, edit it, zip it and upload it here; then pick it for a server profile. MikroTik hotspot page sets work too.'), ' ',
				E('a', { 'href': DOCS, 'target': '_blank', 'rel': 'noreferrer' }, _('Documentation'))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Sample')),
				E('p', _('The "classic" set: the page variables, a CHAP login form, three colour themes and a README that explains it all.')),
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, 'download', SAMPLE) }, _('Download sample'))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Page sets')),
				table
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Upload')),
				E('p', _('A zip with login.html at the top or inside one folder. Allowed: %s. At most %s per file, %s and %d files per set.').format(
					this.info.extensions.join(', '), '%1024.2mB'.format(l.file), '%1024.2mB'.format(l.total), l.files)),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Zip file')),
					E('div', { 'class': 'cbi-value-field' }, fileInput)
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Name')),
					E('div', { 'class': 'cbi-value-field' }, nameInput)
				]),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'btn cbi-button-apply',
						'click': ui.createHandlerFn(this, function() { return this.upload(this.info, fileInput, nameInput); })
					}, _('Upload'))
				])
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
