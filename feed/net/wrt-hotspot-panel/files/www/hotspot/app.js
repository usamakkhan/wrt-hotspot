/* WrtHotspot operator panel: vouchers, users, sessions, history, reports.
 * Talks to hotspotd through rpcd's /ubus JSON-RPC endpoint with the
 * operator's own rpcd session; rpcd ACLs decide what each role may do.
 * No external libraries: the router may be offline. */
'use strict';

(function () {
	var NULL_SID = '00000000000000000000000000000000';
	var S = { sid: null, user: '', admin: false, profiles: {}, servers: [] };
	var timers = [];

	/* ---------- helpers ---------- */

	function h(tag, attrs) {
		var el = document.createElement(tag);
		attrs = attrs || {};

		Object.keys(attrs).forEach(function (k) {
			var v = attrs[k];
			if (v == null || v === false) return;
			if (k === 'class') el.className = v;
			else if (k.slice(0, 2) === 'on') el.addEventListener(k.slice(2), v);
			else if (k === 'value') el.value = v;
			else if (k === 'checked') el.checked = !!v;
			else el.setAttribute(k, v === true ? '' : v);
		});

		for (var i = 2; i < arguments.length; i++) append(el, arguments[i]);
		return el;
	}

	function append(el, c) {
		if (c == null || c === false) return;
		if (Array.isArray(c)) { c.forEach(function (x) { append(el, x); }); return; }
		el.appendChild(c instanceof Node ? c : document.createTextNode(String(c)));
	}

	function clear(el) { while (el.firstChild) el.removeChild(el.firstChild); return el; }

	function toast(msg, err) {
		var t = h('div', { 'class': 'toast' + (err ? ' err' : '') }, msg);
		document.getElementById('toasts').appendChild(t);
		setTimeout(function () { t.remove(); }, err ? 6000 : 3000);
	}

	function bytes(n) {
		n = +n || 0;
		if (n >= 1073741824) return (n / 1073741824).toFixed(2) + ' GiB';
		if (n >= 1048576) return (n / 1048576).toFixed(1) + ' MiB';
		if (n >= 1024) return (n / 1024).toFixed(1) + ' KiB';
		return n + ' B';
	}

	function dur(s) {
		s = Math.max(0, Math.floor(+s || 0));
		if (!s) return '0s';
		var out = '', u = [['w', 604800], ['d', 86400], ['h', 3600], ['m', 60], ['s', 1]];
		u.forEach(function (x) { if (s >= x[1]) { out += Math.floor(s / x[1]) + x[0]; s %= x[1]; } });
		return out;
	}

	function when(t) {
		if (!t) return '-';
		var d = new Date(t * 1000);
		return d.toLocaleDateString() + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
	}

	function money(v) { return (+v || 0).toFixed(2); }

	// Days are the router's days (reports group by its local time), whatever
	// time zone the browser is in. S.tz = the router's UTC offset in seconds.
	function tz() { return S.tz != null ? S.tz : -new Date().getTimezoneOffset() * 60; }

	// Start (unix time) of the router's day containing `d` (ms, as Date.now()).
	function dayStart(d) {
		var t = Math.floor(d / 1000) + tz();
		return t - (((t % 86400) + 86400) % 86400) - tz();
	}

	// YYYY-MM-DD of the router's day containing unix time t.
	function ymd(t) {
		var d = new Date((t + tz()) * 1000);
		return d.getUTCFullYear() + '-' + String(d.getUTCMonth() + 1).padStart(2, '0') + '-' + String(d.getUTCDate()).padStart(2, '0');
	}

	function csv(rows, name) {
		var text = rows.map(function (r) {
			return r.map(function (c) {
				c = String(c == null ? '' : c);
				// A cell starting like a formula would run in Excel/LibreOffice
				// (user names and comments come from staff input).
				if (/^[=+\-@\t\r]/.test(c)) c = "'" + c;
				return /[",\r\n]/.test(c) ? '"' + c.replace(/"/g, '""') + '"' : c;
			}).join(',');
		}).join('\r\n');
		var a = h('a', { href: URL.createObjectURL(new Blob([text], { type: 'text/csv' })), download: name });
		document.body.appendChild(a); a.click(); a.remove();
	}

	function stored(k, dflt) { try { var v = localStorage.getItem('hs.' + k); return v == null ? dflt : JSON.parse(v); } catch (e) { return dflt; } }
	function store(k, v) { try { localStorage.setItem('hs.' + k, JSON.stringify(v)); } catch (e) {} }

	/* ---------- RPC ---------- */

	var rid = 0;

	function rpc(object, method, args) {
		return fetch('/ubus', {
			method: 'POST', headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ jsonrpc: '2.0', id: ++rid, method: 'call', params: [S.sid || NULL_SID, object, method, args || {}] })
		}).then(function (r) { return r.json(); }).then(function (r) {
			if (r.error) {
				// -32002 means "session expired" *or* "not allowed": only the
				// former should send the operator back to the login page.
				if (r.error.code === -32002 && S.sid && object !== 'session')
					return sessionValid().then(function (valid) {
						if (!valid) logout(true);
						throw new Error(valid ? 'permission denied' : 'session expired');
					});
				throw new Error(r.error.message || 'request failed');
			}
			if (r.result[0] === 6) throw new Error('permission denied');
			if (r.result[0] !== 0) throw new Error('error ' + r.result[0]);
			var res = r.result[1] || {};
			if (res.ok === false) { var err = new Error(res.error || 'failed'); err.result = res; throw err; }
			return res;
		});
	}

	function sessionValid() {
		return rpc('session', 'access', { scope: 'ubus', object: 'wrthotspot', 'function': 'whoami' })
			.then(function (r) { return !!r.access; }, function () { return false; });
	}

	function hs(method, args) { return rpc('wrthotspot', method, args); }

	function fail(e) { toast(e.message || String(e), true); }

	// Creating users/vouchers beyond the router's capacity: admins may add them
	// anyway after a warning, operators only see why it was refused.
	// Resolves to the result, or null when the admin cancels.
	function hsCreate(method, args) {
		return hs(method, args).catch(function (e) {
			var cap = e.result && e.result.capacity;
			if (!cap || !S.admin) throw e;
			return new Promise(function (resolve, reject) {
				var done = false;
				modal('Above this router\'s capacity', h('div', {},
					h('p', {}, e.message),
					h('p', { 'class': 'muted' }, (cap.tier || {}).label + ' RAM tier, ' + cap.mode + ' mode: ' + cap.users + ' of ' +
						cap.max_users + ' user accounts. More accounts use more memory and flash and can slow the router down.')),
				[{ label: 'Add anyway', cls: 'danger', run: function () {
					done = true;
					var b = {};
					Object.keys(args).forEach(function (k) { b[k] = args[k]; });
					b.force = true;
					// Either way the dialog closes and the caller gets the outcome
					// (and reports a failure once).
					return hs(method, b).then(function (r) { if (r.warning) toast(r.warning, true); resolve(r); },
						function (x) { reject(x); });
				} }], function () { if (!done) resolve(null); });
			});
		});
	}

	/* ---------- modal ---------- */

	// onClose: called once when the dialog goes away (any button or backdrop).
	function modal(title, body, actions, onClose) {
		var bd = h('div', { 'class': 'backdrop', onclick: function (e) { if (e.target === bd) close(); } });
		var closed = false;
		function close() { if (closed) return; closed = true; bd.remove(); if (onClose) onClose(); }
		var foot = h('div', { 'class': 'foot' }, h('button', { 'class': 'btn', type: 'button', onclick: close }, 'Cancel'));
		(actions || []).forEach(function (a) {
			var btn = h('button', { 'class': 'btn ' + (a.cls || 'primary'), type: 'button', onclick: function () {
				// One request at a time: a double click must not save twice.
				if (btn.disabled) return;
				var r = a.run();
				if (r && r.then) {
					btn.disabled = true;
					r.then(function (keep) { btn.disabled = false; if (keep !== true) close(); },
						function (e) { btn.disabled = false; fail(e); });
				}
				else if (r !== false) close();
			} }, a.label);
			foot.appendChild(btn);
		});
		bd.appendChild(h('div', { 'class': 'modal' }, h('h3', {}, title), body, foot));
		document.body.appendChild(bd);
		var first = bd.querySelector('input, select');
		if (first) first.focus();
		return close;
	}

	function field(label, input, cls) {
		return h('label', { 'class': 'f' + (cls ? ' ' + cls : '') }, label, input);
	}

	function input(type, value, attrs) {
		var a = attrs || {}; a.type = type; a.value = value == null ? '' : value;
		return h('input', a);
	}

	function select(options, value) {
		// A current value missing from the list (profile renamed, RADIUS
		// group) stays selectable instead of silently becoming the first.
		if (value != null && value !== '' && !options.some(function (o) { return (Array.isArray(o) ? o[0] : o) === value; }))
			options = options.concat([value]);
		return h('select', {}, options.map(function (o) {
			var v = Array.isArray(o) ? o[0] : o, l = Array.isArray(o) ? o[1] : o;
			return h('option', { value: v, selected: v === value }, l);
		}));
	}

	function profileNames() {
		var n = Object.keys(S.profiles);
		if (n.indexOf('default') < 0) n.unshift('default');
		return n.sort();
	}

	/* ---------- session ---------- */

	function logout(expired) {
		if (S.sid && !expired) rpc('session', 'destroy', {}).catch(function () {});
		S.sid = null;
		try { sessionStorage.removeItem('hs.sid'); } catch (e) {}
		if (expired) toast('Your session has expired, please log in again.', true);
		render();
	}

	function afterLogin() {
		return Promise.all([hs('whoami'), hs('profiles')]).then(function (r) {
			S.user = r[0].username; S.admin = r[0].admin; S.tz = r[0].tz_offset;
			S.profiles = r[1].user_profiles || {}; S.servers = r[1].servers || [];
			render();
		});
	}

	function viewLogin() {
		var u = input('text', '', { autocomplete: 'username', required: true });
		var p = input('password', '', { autocomplete: 'current-password', required: true });
		var form = h('form', { onsubmit: function (e) {
			e.preventDefault();
			// rpcd's default is 300 s idle: too short to fill in a form.
			rpc('session', 'login', { username: u.value.trim(), password: p.value, timeout: 3600 }).then(function (r) {
				S.sid = r.ubus_rpc_session;
				try { sessionStorage.setItem('hs.sid', S.sid); } catch (e) {}
				return afterLogin();
			}).catch(function () { toast('Login failed: wrong user name or password', true); p.value = ''; p.focus(); });
		} }, field('User name', u), field('Password', p), h('button', { 'class': 'btn primary', type: 'submit' }, 'Log in'));

		return h('div', { 'class': 'login card' }, h('h1', {}, 'Hotspot operator panel'),
			h('div', { 'class': 'muted' }, 'Log in with your operator account.'), form);
	}

	/* ---------- views ---------- */

	var VIEWS = {
		dashboard: ['Dashboard', viewDashboard],
		vouchers: ['Vouchers', viewVouchers],
		users: ['Users', viewUsers],
		sessions: ['Online now', viewSessions],
		history: ['History', viewHistory],
		reports: ['Reports', viewReports],
		operators: ['Operators', viewOperators, true]
	};

	function every(sec, fn) { fn(); timers.push(setInterval(fn, sec * 1000)); }

	function render() {
		timers.forEach(clearInterval); timers = [];
		var app = clear(document.getElementById('app'));

		if (!S.sid) { app.appendChild(viewLogin()); return; }

		var name = (location.hash || '#dashboard').slice(1);
		if (!VIEWS[name] || (VIEWS[name][2] && !S.admin)) name = 'dashboard';

		var nav = h('nav', { 'class': 'side' }, h('div', { 'class': 'brand' }, 'Hotspot'));
		Object.keys(VIEWS).forEach(function (k) {
			if (VIEWS[k][2] && !S.admin) return;
			nav.appendChild(h('a', { href: '#' + k, 'class': k === name ? 'active' : null }, VIEWS[k][0]));
		});
		nav.appendChild(h('div', { 'class': 'spacer' }));
		nav.appendChild(h('div', { 'class': 'who' }, S.user + (S.admin ? ' (admin)' : '')));
		nav.appendChild(h('a', { href: '#', onclick: function (e) { e.preventDefault(); logout(); } }, 'Log out'));

		var main = h('main', { 'class': 'main' });
		app.appendChild(h('div', { 'class': 'shell' }, nav, main));
		VIEWS[name][1](main);
	}

	window.addEventListener('hashchange', render);

	/* Dashboard */

	function barChart(rows, key, label) {
		var w = 600, hgt = 180, pad = 22, n = Math.max(rows.length, 1);
		var maxv = Math.max.apply(null, rows.map(function (r) { return r[key] || 0; }).concat([1]));
		var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
		svg.setAttribute('viewBox', '0 0 ' + w + ' ' + hgt); svg.setAttribute('class', 'chart');
		var bw = (w - pad) / n;
		rows.forEach(function (r, i) {
			var v = r[key] || 0, bh = (hgt - pad - 14) * v / maxv;
			var rect = document.createElementNS(svg.namespaceURI, 'rect');
			rect.setAttribute('class', 'bar'); rect.setAttribute('x', pad + i * bw + bw * 0.15); rect.setAttribute('width', bw * 0.7);
			rect.setAttribute('y', hgt - pad - bh); rect.setAttribute('height', Math.max(bh, v ? 1 : 0));
			var t = document.createElementNS(svg.namespaceURI, 'title'); t.textContent = r.key + ': ' + label(v); rect.appendChild(t);
			svg.appendChild(rect);
			var tx = document.createElementNS(svg.namespaceURI, 'text');
			tx.setAttribute('x', pad + i * bw + bw / 2); tx.setAttribute('y', hgt - 6); tx.setAttribute('text-anchor', 'middle');
			tx.textContent = String(r.key).slice(5); svg.appendChild(tx);
		});
		return svg;
	}

	function viewDashboard(main) {
		main.appendChild(h('h1', {}, 'Dashboard'));
		var tiles = h('div', { 'class': 'tiles' }), charts = h('div');
		main.appendChild(tiles); main.appendChild(charts);

		every(15, function () {
			var now = Math.floor(Date.now() / 1000), today = dayStart(Date.now());
			Promise.all([hs('report', { from: today, to: now + 60, group: 'day' }), hs('report', { from: today - 6 * 86400, to: now + 60, group: 'day' })]).then(function (r) {
				var t = r[0].total;
				clear(tiles);
				[['Online now', r[0].online], ['Sessions today', t.sessions], ['Users today', t.users],
				 ['Traffic today', bytes(t.bytes_in + t.bytes_out)], ['Vouchers sold today', t.activations], ['Revenue today', money(t.revenue)]]
					.forEach(function (x) { tiles.appendChild(h('div', { 'class': 'tile' }, h('div', { 'class': 'v' }, x[1]), h('div', { 'class': 'l' }, x[0]))); });

				// Last 7 days, including days without data.
				var by = {}; r[1].rows.forEach(function (x) { by[x.key] = x; });
				var days = [];
				for (var i = 6; i >= 0; i--) {
					var k = ymd(today - i * 86400);
					days.push(by[k] || { key: k, sessions: 0, revenue: 0 });
				}

				clear(charts);
				charts.appendChild(h('div', { 'class': 'card' }, h('h2', { style: 'margin-top:0' }, 'Sessions, last 7 days'), barChart(days, 'sessions', String)));
				charts.appendChild(h('div', { 'class': 'card' }, h('h2', { style: 'margin-top:0' }, 'Revenue, last 7 days'), barChart(days, 'revenue', money)));
			}).catch(fail);
		});
	}

	/* Vouchers */

	var PRINT_DEFAULTS = { title: 'Wi-Fi access', note: 'Connect to the Wi-Fi and enter the code on the login page.', template: 'cards', price: true };

	function printVouchers(batch, list) {
		var o = stored('print', PRINT_DEFAULTS);
		var title = input('text', o.title), note = input('text', o.note);
		var tpl = select([['cards', 'Cards (3 per row)'], ['tickets', 'Small tickets (4 per row)'], ['list', 'List']], o.template);
		var price = h('input', { type: 'checkbox', checked: o.price });
		var unused = h('input', { type: 'checkbox', checked: true });

		modal('Print batch ' + batch.batch, h('div', { 'class': 'grid' },
			field('Title', title, 'full'), field('Note', note, 'full'), field('Layout', tpl),
			h('label', { 'class': 'check' }, price, 'Show price'), h('label', { 'class': 'check' }, unused, 'Only unused vouchers')),
		[{ label: 'Print', run: function () {
			var opt = { title: title.value, note: note.value, template: tpl.value, price: price.checked };
			store('print', opt);
			var items = list.filter(function (v) { return !unused.checked || !v.used; });
			var meta = [];
			if (batch.validity) meta.push('Valid ' + dur(batch.validity) + ' from first use');
			if (opt.price && batch.price) meta.push('Price ' + batch.price);
			var pr = clear(document.getElementById('print'));
			pr.appendChild(h('div', { 'class': 'vouchers ' + opt.template }, items.map(function (v) {
				return h('div', { 'class': 'voucher' },
					h('div', { 'class': 't' }, opt.title),
					h('div', { 'class': 'code' }, v.name),
					v.password !== v.name ? h('div', { 'class': 'pw' }, 'Password: ' + v.password) : null,
					h('div', { 'class': 'meta' }, meta.join(' · ')),
					opt.template !== 'list' ? h('div', { 'class': 'meta' }, opt.note) : null);
			})));
			document.body.classList.add('printing');
			window.addEventListener('afterprint', function done() { document.body.classList.remove('printing'); window.removeEventListener('afterprint', done); });
			setTimeout(function () { window.print(); }, 50);
		} }]);
	}

	function viewVouchers(main) {
		main.appendChild(h('h1', {}, 'Vouchers'));

		var f = {
			profile: select(profileNames(), 'default'), count: input('number', 10, { min: 1, max: 1000 }),
			prefix: input('text', '', { maxlength: 8, placeholder: 'optional' }), length: input('number', 6, { min: 4, max: 16 }),
			charset: select([['alnum', 'letters + digits'], ['digits', 'digits'], ['lower', 'letters'], ['upper', 'CAPITALS'], ['mixed', 'Mixed case + digits']], 'alnum'),
			password: select([['same', 'Code only (PIN)'], ['separate', 'Code + password']], 'same'),
			validity: input('text', '', { placeholder: 'e.g. 1d, 3h' }), limit_uptime: input('text', '', { placeholder: 'e.g. 5h' }),
			limit_bytes_total: input('text', '', { placeholder: 'e.g. 2G' }), price: input('text', '', { placeholder: 'e.g. 2.50' }),
			comment: input('text', '')
		};

		main.appendChild(h('div', { 'class': 'card' },
			h('h2', { style: 'margin-top:0' }, 'New batch'),
			h('div', { 'class': 'row' },
				field('Profile', f.profile), field('How many', f.count), field('Prefix', f.prefix), field('Code length', f.length),
				field('Characters', f.charset), field('Login with', f.password)),
			h('div', { 'class': 'row', style: 'margin-top:10px' },
				field('Valid for (from first use)', f.validity), field('Online time', f.limit_uptime), field('Data', f.limit_bytes_total),
				field('Price', f.price), field('Note', f.comment, 'grow'),
				h('button', { 'class': 'btn primary', onclick: function (ev) {
					// A double click must not create two batches.
					var btn = ev.currentTarget;
					if (btn.disabled) return;
					var a = {};
					Object.keys(f).forEach(function (k) { a[k] = f[k].value.trim(); });
					a.count = +a.count; a.length = +a.length;
					btn.disabled = true;
					hsCreate('voucher_create', a).then(function (r) {
						if (!r) return;
						toast(r.vouchers.length + ' vouchers created in ' + r.batch);
						loadBatches();
					}).catch(fail).then(function () { btn.disabled = false; });
				} }, 'Create'))));

		var tbody = h('tbody');
		main.appendChild(h('div', { 'class': 'card' }, h('h2', { style: 'margin-top:0' }, 'Batches'),
			h('div', { 'class': 'tablewrap' }, h('table', {},
				h('thead', {}, h('tr', {}, ['Batch', 'Created', 'By', 'Profile', 'Vouchers', 'Used', 'Valid for', 'Price', 'Note', ''].map(function (t) { return h('th', {}, t); }))),
				tbody))));

		function loadBatches() {
			hs('voucher_batches').then(function (r) {
				clear(tbody);
				if (!r.batches.length) tbody.appendChild(h('tr', {}, h('td', { colspan: 10, 'class': 'empty' }, 'No vouchers yet')));
				r.batches.forEach(function (b) {
					tbody.appendChild(h('tr', {},
						h('td', { 'class': 'nowrap' }, b.batch), h('td', {}, when(b.created)), h('td', {}, b.created_by || '-'), h('td', {}, b.profile),
						h('td', {}, b.count), h('td', {}, b.used + (b.expired ? ' (' + b.expired + ' expired)' : '')),
						h('td', {}, b.validity ? dur(b.validity) : '-'), h('td', {}, b.price || '-'), h('td', {}, b.comment || ''),
						h('td', { 'class': 'actions' },
							h('button', { 'class': 'btn small', onclick: function () {
								hs('voucher_list', { batch: b.batch }).then(function (l) { printVouchers(b, l.vouchers); }).catch(fail);
							} }, 'Print'),
							h('button', { 'class': 'btn small', onclick: function () {
								hs('voucher_list', { batch: b.batch }).then(function (l) {
									csv([['code', 'password', 'used']].concat(l.vouchers.map(function (v) { return [v.name, v.password, v.used ? 'yes' : 'no']; })), b.batch + '.csv');
								}).catch(fail);
							} }, 'CSV'),
							h('button', { 'class': 'btn small danger', onclick: function () {
								modal('Revoke ' + b.batch + '?', h('p', {}, 'The ' + (b.count - b.used) + ' unused vouchers of this batch are deleted. Used ones stay.'),
									[{ label: 'Revoke unused', cls: 'danger', run: function () {
										return hs('voucher_revoke', { batch: b.batch }).then(function (r) { toast(r.count + ' vouchers revoked'); loadBatches(); });
									} }]);
							} }, 'Revoke'))));
				});
			}).catch(fail);
		}

		loadBatches();
	}

	/* Users */

	function editUser(u, done) {
		var isNew = !u;
		u = u || { profile: 'default', server: 'all' };
		var f = {
			name: input('text', u.name, { disabled: !isNew }), password: input('text', '', { placeholder: isNew ? '' : 'unchanged' }),
			profile: select(profileNames(), u.profile), server: select(['all'].concat(S.servers), u.server || 'all'),
			mac: input('text', u.mac, { placeholder: 'any device' }),
			validity: input('text', u.validity ? dur(u.validity) : '', { placeholder: 'from first login' }),
			limit_uptime: input('text', u.limit_uptime ? dur(u.limit_uptime) : ''), limit_bytes_total: input('text', u.limit_bytes_total || ''),
			limit_bytes_in: input('text', u.limit_bytes_in || ''), limit_bytes_out: input('text', u.limit_bytes_out || ''),
			price: input('text', u.price), comment: input('text', u.comment), email: input('text', u.email),
			disabled: h('input', { type: 'checkbox', checked: u.disabled })
		};

		modal(isNew ? 'Add user' : 'Edit ' + u.name, h('div', { 'class': 'grid' },
			field('Name', f.name), field('Password', f.password), field('Profile', f.profile), field('Server', f.server),
			field('Bound to MAC', f.mac), field('Valid for', f.validity), field('Online time limit', f.limit_uptime),
			field('Data limit (total)', f.limit_bytes_total), field('Upload limit', f.limit_bytes_in), field('Download limit', f.limit_bytes_out),
			field('Price', f.price), field('E-mail', f.email), field('Comment', f.comment, 'full'),
			h('label', { 'class': 'check' }, f.disabled, 'Disabled')),
		[{ label: 'Save', run: function () {
			var a = {};
			Object.keys(f).forEach(function (k) { a[k] = (k === 'disabled') ? f[k].checked : f[k].value.trim(); });
			if (!isNew) { a.name = u.name; if (a.password === '') delete a.password; }
			if (!a.name) { toast('A name is required', true); return false; }
			return (isNew ? hsCreate('user_set', a) : hs('user_set', a)).then(function (r) {
				if (!r) return true;	// capacity warning cancelled: keep the form open
				toast('Saved'); done();
			});
		} }]);
	}

	function extendUser(u, done) {
		var by = input('text', '1d');
		modal('Extend ' + u.name, h('div', {},
			h('p', { 'class': 'muted' }, u.expires ? 'Expires ' + when(u.expires) + '.' : 'Not started yet: the validity is extended instead.'),
			field('Add', by)),
		[{ label: 'Extend', run: function () {
			var m = by.value.trim().match(/^(\d+)([mhdw])$/);
			if (!m) { toast('Use e.g. 30m, 6h, 1d, 1w', true); return false; }
			var secs = +m[1] * { m: 60, h: 3600, d: 86400, w: 604800 }[m[2]];
			var now = Math.floor(Date.now() / 1000);
			var a = { name: u.name };
			// Running: move the end. Not used yet: lengthen the validity that
			// starts at first login. Used without any end: set one from now.
			var used = u.used && (u.used.uptime || u.used.bytes_in || u.used.bytes_out);
			if (u.expires) a.expires = String(Math.max(now, u.expires) + secs);
			else if (u.validity && !used) a.validity = String(u.validity + secs);
			else a.expires = String(now + secs);
			return hs('user_set', a).then(function () { toast('Extended'); done(); });
		} }]);
	}

	function userState(u) {
		var now = Date.now() / 1000;
		if (u.disabled) return h('span', { 'class': 'badge muted' }, 'disabled');
		if (u.expires && u.expires <= now) return h('span', { 'class': 'badge err' }, 'expired');
		if (u.first_login) return h('span', { 'class': 'badge ok' }, 'active');
		return h('span', { 'class': 'badge warn' }, u.batch ? 'unused' : 'new');
	}

	function viewUsers(main) {
		var search = input('search', stored('usersearch', ''), { placeholder: 'Search name, comment, batch' });
		var tbody = h('tbody'), more = h('div'), count = h('div', { 'class': 'muted', style: 'margin:0 0 8px' });
		var list = [], total = 0, timer = null;

		main.appendChild(h('h1', {}, 'Users'));
		main.appendChild(h('div', { 'class': 'row', style: 'margin-bottom:12px' }, h('div', { 'class': 'grow' }, search),
			h('button', { 'class': 'btn primary', onclick: function () { editUser(null, function () { load(false); }); } }, 'Add user')));
		main.appendChild(count);
		main.appendChild(h('div', { 'class': 'card' }, h('div', { 'class': 'tablewrap' }, h('table', {},
			h('thead', {}, h('tr', {}, ['Name', 'Profile', 'State', 'Expires', 'Used', 'Limits', 'Comment', ''].map(function (t) { return h('th', {}, t); }))),
			tbody)), more));

		// Searching and paging happen on the router: there can be thousands of vouchers.
		search.addEventListener('input', function () {
			store('usersearch', search.value);
			clearTimeout(timer);
			timer = setTimeout(function () { load(false); }, 300);
		});

		function reload() { load(false); }

		function draw() {
			clear(tbody); clear(more);
			count.textContent = total ? ('Showing ' + list.length + ' of ' + total) : '';
			if (!list.length) tbody.appendChild(h('tr', {}, h('td', { colspan: 8, 'class': 'empty' }, 'No users')));
			list.forEach(function (u) {
				var used = u.used || {}, lim = [];
				if (u.limit_uptime) lim.push(dur(u.limit_uptime));
				if (u.limit_bytes_total) lim.push(bytes(u.limit_bytes_total));
				if (u.validity) lim.push('valid ' + dur(u.validity));
				tbody.appendChild(h('tr', {},
					h('td', { 'class': 'nowrap' }, h('strong', {}, u.name)), h('td', {}, u.profile), h('td', {}, userState(u)),
					h('td', { 'class': 'nowrap' }, when(u.expires)),
					h('td', { 'class': 'nowrap' }, dur(used.uptime) + ' · ' + bytes((used.bytes_in || 0) + (used.bytes_out || 0))),
					h('td', {}, lim.join(', ') || '-'), h('td', {}, u.comment || (u.batch ? u.batch : '')),
					h('td', { 'class': 'actions' },
						h('button', { 'class': 'btn small', onclick: function () { editUser(u, reload); } }, 'Edit'),
						h('button', { 'class': 'btn small', onclick: function () { extendUser(u, reload); } }, 'Extend'),
						h('button', { 'class': 'btn small', onclick: function () {
							hs('user_reset_counters', { name: u.name }).then(function () { toast('Counters reset'); reload(); }).catch(fail);
						} }, 'Reset'),
						h('button', { 'class': 'btn small danger', onclick: function () {
							modal('Delete ' + u.name + '?', h('p', {}, 'The user is deleted and logged out.'), [{ label: 'Delete', cls: 'danger', run: function () {
								return hs('user_remove', { name: u.name }).then(function () { toast('Deleted'); reload(); });
							} }]);
						} }, 'Delete'))));
			});
			if (total > list.length)
				more.appendChild(h('div', { style: 'text-align:center;margin-top:10px' },
					h('button', { 'class': 'btn', onclick: function () { load(true); } }, 'Show more (' + (total - list.length) + ' left)')));
		}

		var seq = 0;
		function load(append) {
			// Only the newest search may draw: an older, slower answer must not
			// replace it.
			var my = ++seq;
			hs('user_list', { offset: append ? list.length : 0, limit: 200, search: search.value.trim() }).then(function (r) {
				if (my !== seq) return;
				list = append ? list.concat(r.users) : r.users;
				total = r.total || list.length;
				draw();
			}).catch(fail);
		}

		load(false);
	}

	/* Online now */

	function viewSessions(main) {
		var tbody = h('tbody'), count = h('div', { 'class': 'muted', style: 'margin:0 0 8px' });
		var search = input('search', '', { placeholder: 'Search user, MAC or IP' });
		main.appendChild(h('h1', {}, 'Online now'));
		main.appendChild(h('div', { 'class': 'row', style: 'margin-bottom:12px' }, h('div', { 'class': 'grow' }, search)));
		main.appendChild(count);
		main.appendChild(h('div', { 'class': 'card' }, h('div', { 'class': 'tablewrap' }, h('table', {},
			h('thead', {}, h('tr', {}, ['User', 'Device', 'Addresses', 'Since', 'Time left', 'Data', 'Rate limit', ''].map(function (t) { return h('th', {}, t); }))),
			tbody))));

		function refresh() {
			hs('sessions', { limit: 300, search: search.value.trim() }).then(function (r) {
				clear(tbody);
				count.textContent = (r.total > r.sessions.length) ? ('Showing ' + r.sessions.length + ' of ' + r.total + ' - search to narrow down') : (r.total + ' online');
				if (!r.sessions.length) tbody.appendChild(h('tr', {}, h('td', { colspan: 8, 'class': 'empty' }, 'Nobody is online')));
				r.sessions.forEach(function (s) {
					tbody.appendChild(h('tr', {},
						h('td', {}, h('strong', {}, s.user), h('div', { 'class': 'muted' }, s.login_by)),
						h('td', { 'class': 'nowrap' }, s.mac),
						h('td', {}, (s.ipv4 || []).join(', ') || '-', s.ipv6 && s.ipv6.length ? h('div', { 'class': 'muted' }, s.ipv6.length + ' IPv6') : null),
						h('td', { 'class': 'nowrap' }, dur(s.uptime)),
						h('td', {}, s.session_time_left != null ? dur(s.session_time_left) : '∞'),
						h('td', { 'class': 'nowrap' }, '↑' + bytes(s.bytes_in) + ' ↓' + bytes(s.bytes_out)),
						h('td', {}, s.rate_limit || '-'),
						h('td', { 'class': 'actions' }, h('button', { 'class': 'btn small danger', onclick: function () {
							hs('logout', { id: s.id, cause: 'admin-reset' }).then(function () { toast(s.user + ' logged out'); refresh(); }).catch(fail);
						} }, 'Log out'))));
				});
			}).catch(fail);
		}

		search.addEventListener('input', function () { clearTimeout(search._t); search._t = setTimeout(refresh, 300); });
		every(5, refresh);
	}

	/* History */

	function dateInput(t) { return input('date', ymd(t)); }
	// The router's midnight of the chosen date (+1 day for an inclusive end).
	function dateValue(el, end) {
		var p = el.value.split('-');
		return Math.floor(Date.UTC(+p[0], +p[1] - 1, +p[2]) / 1000) - tz() + (end ? 86400 : 0);
	}

	function viewHistory(main) {
		var now = Date.now() / 1000;
		var from = dateInput(dayStart(Date.now()) - 6 * 86400), to = dateInput(now);
		var q = input('search', '', { placeholder: 'user, MAC, IP or batch' });
		var tbody = h('tbody'), rows = [];

		main.appendChild(h('h1', {}, 'History'));
		main.appendChild(h('div', { 'class': 'row', style: 'margin-bottom:12px' }, field('From', from), field('To', to), field('Search', q, 'grow'),
			h('button', { 'class': 'btn primary', onclick: load }, 'Show'),
			h('button', { 'class': 'btn', onclick: function () {
				csv([['start', 'end', 'user', 'mac', 'ipv4', 'server', 'login_by', 'uptime_s', 'bytes_in', 'bytes_out', 'cause', 'batch']].concat(rows.map(function (e) {
					return [new Date(e.start * 1000).toISOString(), new Date(e.end * 1000).toISOString(), e.user, e.mac, e.ipv4, e.server, e.login_by, e.uptime, e.bytes_in, e.bytes_out, e.cause, e.batch];
				})), 'hotspot-history.csv');
			} }, 'CSV')));
		main.appendChild(h('div', { 'class': 'card' }, h('div', { 'class': 'tablewrap' }, h('table', {},
			h('thead', {}, h('tr', {}, ['Start', 'User', 'Device', 'Duration', 'Data', 'Ended by', 'Server'].map(function (t) { return h('th', {}, t); }))),
			tbody))));

		function load() {
			hs('history', { from: dateValue(from), to: dateValue(to, true), search: q.value.trim(), limit: 1000 }).then(function (r) {
				rows = r.history;
				clear(tbody);
				if (!rows.length) tbody.appendChild(h('tr', {}, h('td', { colspan: 7, 'class': 'empty' }, 'No sessions in this period')));
				rows.forEach(function (e) {
					tbody.appendChild(h('tr', {},
						h('td', { 'class': 'nowrap' }, when(e.start)), h('td', {}, h('strong', {}, e.user), e.batch ? h('div', { 'class': 'muted' }, e.batch) : null),
						h('td', { 'class': 'nowrap' }, e.mac, h('div', { 'class': 'muted' }, e.ipv4 || '')),
						h('td', {}, dur(e.uptime)), h('td', { 'class': 'nowrap' }, '↑' + bytes(e.bytes_in) + ' ↓' + bytes(e.bytes_out)),
						h('td', {}, e.cause), h('td', {}, e.server)));
				});
			}).catch(fail);
		}

		load();
	}

	/* Reports */

	function viewReports(main) {
		var today = dayStart(Date.now());
		var from = dateInput(today - 29 * 86400), to = dateInput(today);
		var group = select([['day', 'Day'], ['hour', 'Hour'], ['user', 'User'], ['batch', 'Voucher batch'], ['profile', 'Profile'], ['server', 'Server'], ['login_by', 'Login method']], 'day');
		var tiles = h('div', { 'class': 'tiles' }), chart = h('div'), tbody = h('tbody'), last = null;

		function preset(label, days) {
			return h('button', { 'class': 'btn small', onclick: function () {
				var t = dayStart(Date.now());
				from.value = ymd(t - (days - 1) * 86400);
				to.value = ymd(t);
				load();
			} }, label);
		}

		main.appendChild(h('h1', {}, 'Reports'));
		main.appendChild(h('div', { 'class': 'row', style: 'margin-bottom:8px' }, preset('Today', 1), preset('7 days', 7), preset('30 days', 30), preset('90 days', 90)));
		main.appendChild(h('div', { 'class': 'row', style: 'margin-bottom:12px' }, field('From', from), field('To', to), field('Group by', group),
			h('button', { 'class': 'btn primary', onclick: load }, 'Show'),
			h('button', { 'class': 'btn', onclick: function () {
				if (!last) return;
				csv([['key', 'sessions', 'users', 'devices', 'uptime_s', 'bytes_in', 'bytes_out', 'vouchers_sold', 'revenue']].concat(last.rows.map(function (r) {
					return [r.key, r.sessions, r.users, r.devices, r.uptime, r.bytes_in, r.bytes_out, r.activations, money(r.revenue)];
				})), 'hotspot-report.csv');
			} }, 'CSV')));
		main.appendChild(tiles);
		main.appendChild(chart);
		main.appendChild(h('div', { 'class': 'card' }, h('div', { 'class': 'tablewrap' }, h('table', {},
			h('thead', {}, h('tr', {}, ['', 'Sessions', 'Users', 'Devices', 'Online time', 'Upload', 'Download', 'Vouchers sold', 'Revenue'].map(function (t) { return h('th', {}, t); }))),
			tbody))));

		function load() {
			hs('report', { from: dateValue(from), to: dateValue(to, true), group: group.value }).then(function (r) {
				last = r;
				var t = r.total;
				clear(tiles);
				[['Sessions', t.sessions], ['Users', t.users], ['Devices', t.devices], ['Online time', dur(t.uptime)],
				 ['Traffic', bytes(t.bytes_in + t.bytes_out)], ['Vouchers sold', t.activations], ['Revenue', money(t.revenue)]]
					.forEach(function (x) { tiles.appendChild(h('div', { 'class': 'tile' }, h('div', { 'class': 'v' }, x[1]), h('div', { 'class': 'l' }, x[0]))); });

				clear(chart);
				if ((group.value === 'day' || group.value === 'hour') && r.rows.length)
					chart.appendChild(h('div', { 'class': 'card' }, barChart(r.rows, 'sessions', String)));

				clear(tbody);
				if (!r.rows.length) tbody.appendChild(h('tr', {}, h('td', { colspan: 9, 'class': 'empty' }, 'No data in this period')));
				r.rows.forEach(function (x) {
					tbody.appendChild(h('tr', {}, h('td', { 'class': 'nowrap' }, h('strong', {}, x.key)), h('td', {}, x.sessions), h('td', {}, x.users),
						h('td', {}, x.devices), h('td', {}, dur(x.uptime)), h('td', {}, bytes(x.bytes_in)), h('td', {}, bytes(x.bytes_out)),
						h('td', {}, x.activations), h('td', {}, money(x.revenue))));
				});
			}).catch(fail);
		}

		load();
	}

	/* Operators (admins only) */

	function viewOperators(main) {
		var tbody = h('tbody');
		main.appendChild(h('h1', {}, 'Operators'));
		main.appendChild(h('p', { 'class': 'muted' }, 'Staff accounts for this panel. Operators manage users, vouchers and sessions; admins can also manage operators. Neither can change the router configuration.'));
		main.appendChild(h('div', { 'class': 'row', style: 'margin-bottom:12px' }, h('button', { 'class': 'btn primary', onclick: function () { edit(null); } }, 'Add operator')));
		main.appendChild(h('div', { 'class': 'card' }, h('table', {},
			h('thead', {}, h('tr', {}, ['User name', 'Role', 'Note', ''].map(function (t) { return h('th', {}, t); }))), tbody)));

		function edit(o) {
			var isNew = !o;
			o = o || { role: 'operator' };
			var u = input('text', o.username, { disabled: !isNew }), p = input('password', '', { placeholder: isNew ? 'at least 6 characters' : 'unchanged', autocomplete: 'new-password' });
			var role = select([['operator', 'Operator'], ['admin', 'Admin']], o.role), note = input('text', o.comment);
			modal(isNew ? 'Add operator' : 'Edit ' + o.username, h('div', { 'class': 'grid' }, field('User name', u), field('Password', p), field('Role', role), field('Note', note)),
				[{ label: 'Save', run: function () {
					return hs('operator_set', { username: isNew ? u.value.trim() : o.username, password: p.value, role: role.value, comment: note.value }).then(function () { toast('Saved'); load(); });
				} }]);
		}

		function load() {
			hs('operator_list').then(function (r) {
				clear(tbody);
				if (!r.operators.length) tbody.appendChild(h('tr', {}, h('td', { colspan: 4, 'class': 'empty' }, 'No operators yet')));
				r.operators.forEach(function (o) {
					tbody.appendChild(h('tr', {}, h('td', {}, h('strong', {}, o.username)), h('td', {}, o.role), h('td', {}, o.comment || ''),
						h('td', { 'class': 'actions' },
							h('button', { 'class': 'btn small', onclick: function () { edit(o); } }, 'Edit'),
							o.username !== S.user ? h('button', { 'class': 'btn small danger', onclick: function () {
								modal('Remove ' + o.username + '?', h('p', {}, 'The account can no longer log in.'), [{ label: 'Remove', cls: 'danger', run: function () {
									return hs('operator_remove', { username: o.username }).then(function () { toast('Removed'); load(); });
								} }]);
							} }, 'Remove') : null)));
				});
			}).catch(fail);
		}

		load();
	}

	/* ---------- start ---------- */

	try { S.sid = sessionStorage.getItem('hs.sid'); } catch (e) {}

	if (S.sid)
		afterLogin().catch(function () { S.sid = null; render(); });
	else
		render();
})();
