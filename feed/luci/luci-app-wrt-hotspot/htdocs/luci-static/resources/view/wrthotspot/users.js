'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require tools.wrthotspot as hs';

var FIELDS = [
	[ 'name', _('Name'), 'text' ],
	[ 'password', _('Password'), 'password' ],
	[ 'profile', _('User profile'), 'profile' ],
	[ 'server', _('Server'), 'server' ],
	[ 'mac', _('Bound to MAC'), 'text', _('Only this device may use the account (empty = any).') ],
	[ 'limit_uptime', _('Uptime limit'), 'text', _('Total over all sessions, e.g. 10h.') ],
	[ 'limit_bytes_in', _('Upload limit'), 'text', _('e.g. 500M') ],
	[ 'limit_bytes_out', _('Download limit'), 'text', _('e.g. 2G') ],
	[ 'limit_bytes_total', _('Transfer limit'), 'text' ],
	[ 'comment', _('Comment'), 'text' ],
	[ 'email', _('E-mail'), 'text' ],
	[ 'disabled', _('Disabled'), 'flag' ]
];

function limitText(u) {
	var parts = [];

	if (u.limit_uptime) parts.push(hs.fmtDuration(u.limit_uptime));
	if (u.limit_bytes_in) parts.push('⇡ ' + hs.fmtBytes(u.limit_bytes_in));
	if (u.limit_bytes_out) parts.push('⇣ ' + hs.fmtBytes(u.limit_bytes_out));
	if (u.limit_bytes_total) parts.push('Σ ' + hs.fmtBytes(u.limit_bytes_total));

	return parts.length ? parts.join(', ') : '-';
}

function editValue(u, key) {
	var v = u ? u[key] : null;

	if (v == null || v === 0 || v === '')
		return '';

	if (key == 'limit_uptime')
		return hs.fmtDuration(v);

	if (/^limit_bytes/.test(key))
		return String(v);

	return String(v);
}

return view.extend({
	load: function() {
		return Promise.all([ hs.users(0, 500, ''), uci.load('wrthotspot') ]);
	},

	refresh: function() {
		var q = document.getElementById('hs-user-search');
		var my = this.seq = (this.seq || 0) + 1;	// only the newest search may draw

		return hs.users(0, 500, q ? q.value.trim() : '').then(L.bind(function(r) {
			if (my !== this.seq)
				return;

			cbi_update_table('#hs-users', this.rows(r.users || []), E('em', _('No users')));
			this.showCount(r);
		}, this));
	},

	showCount: function(r) {
		var el = document.getElementById('hs-user-count');

		if (el)
			el.textContent = (r.total > (r.users || []).length)
				? _('Showing %d of %d users - search to narrow down, or use the operator panel for vouchers.').format(r.users.length, r.total)
				: _('%d users').format(r.total || 0);
	},

	rows: function(users) {
		return users.map(L.bind(function(u) {
			var used = u.used || {};

			return [
				E('strong', hs.h(u.name)),
				hs.h(u.profile),
				hs.h(u.server || 'all'),
				hs.h(u.mac || '-'),
				limitText(u),
				'%s, ⇡%s ⇣%s'.format(hs.fmtDuration(used.uptime), hs.fmtBytes(used.bytes_in), hs.fmtBytes(used.bytes_out)),
				u.disabled ? E('span', { 'class': 'label warning' }, _('disabled')) : _('enabled'),
				hs.h(u.comment || ''),
				E('div', { 'class': 'nowrap' }, [
					E('button', { 'class': 'btn cbi-button-edit', 'click': ui.createHandlerFn(this, 'edit', u) }, _('Edit')), ' ',
					E('button', { 'class': 'btn', 'click': ui.createHandlerFn(this, 'viewPassword', u) }, _('View password')), ' ',
					E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'reset', u) }, _('Reset counters')), ' ',
					E('button', { 'class': 'btn cbi-button-remove', 'click': ui.createHandlerFn(this, 'remove', u) }, _('Delete'))
				])
			];
		}, this));
	},

	viewPassword: function(u) {
		return hs.userPassword(u.name).then(function(res) {
			if (!res || res.ok !== true)
				return ui.addNotification(null, E('p', {}, hs.h(res && res.error ? res.error : _('Unable to read password'))), 'danger');

			ui.showModal(_('Password for %s').format(hs.h(u.name)), [
				E('p', {}, [ E('code', {}, hs.h(res.password || _('(empty)'))) ]),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
				])
			]);
		});
	},

	edit: function(u) {
		var inputs = {};
		var body = [];
		var profiles = uci.sections('wrthotspot', 'user_profile').map(function(p) { return p.name || p['.name']; });
		var servers = [ 'all' ].concat(uci.sections('wrthotspot', 'server').map(function(s) { return s['.name']; }));

		if (profiles.indexOf('default') < 0)
			profiles.unshift('default');

		FIELDS.forEach(function(f) {
			var key = f[0], el;
			var val = editValue(u, key);

			if (f[2] == 'profile' || f[2] == 'server') {
				var opts = (f[2] == 'profile') ? profiles : servers;
				el = E('select', { 'class': 'cbi-input-select' }, opts.map(function(o) {
					return E('option', { 'value': o, 'selected': (u ? u[key] : (f[2] == 'server' ? 'all' : 'default')) == o ? '' : null }, o);
				}));
			}
			else if (f[2] == 'flag') {
				el = E('input', { 'type': 'checkbox', 'checked': (u && u.disabled) ? '' : null });
			}
			else {
				el = E('input', {
					'class': 'cbi-input-text',
					'type': (f[2] == 'password') ? 'password' : 'text',
					'value': (key == 'password') ? '' : val,
					'placeholder': (key == 'password' && u) ? _('unchanged') : '',
					'disabled': (key == 'name' && u) ? '' : null
				});
			}

			inputs[key] = el;
			body.push(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, f[1]),
				E('div', { 'class': 'cbi-value-field' }, [ el, f[3] ? E('div', { 'class': 'cbi-value-description' }, f[3]) : '' ])
			]));
		});

		body.push(E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
			E('button', {
				'class': 'btn cbi-button-positive',
				'click': ui.createHandlerFn(this, function() {
					var v = {};

					FIELDS.forEach(function(f) {
						var el = inputs[f[0]];
						v[f[0]] = (f[2] == 'flag') ? el.checked : el.value.trim();
					});

					if (u)
						v.name = u.name;

					if (!v.name)
						return ui.addNotification(null, E('p', _('A name is required')), 'danger');

					// Keep the password unless a new one was typed.
					if (u && v.password === '')
						v.password = undefined;

					var save = L.bind(function(force) {
						return hs.userSet(v.name, v.password, v.profile, v.server, v.mac, v.limit_uptime,
							v.limit_bytes_in, v.limit_bytes_out, v.limit_bytes_total, v.disabled, v.comment, v.email,
							force ? true : undefined)
						.then(L.bind(function(res) {
							// Above the router's capacity: the admin may add the user anyway.
							if (res && res.ok === false && res.capacity && !force &&
							    confirm(res.error + '\n\n' + _('More user accounts than recommended use more memory and flash and can slow the router down. Add anyway?')))
								return save(true);

							if (res && res.ok === false)
								return ui.addNotification(null, E('p', res.error), 'danger');

							if (res && res.warning)
								ui.addNotification(null, E('p', res.warning), 'warning');

							ui.hideModal();
							return this.refresh();
						}, this));
					}, this);

					return save(false);
				})
			}, _('Save'))
		]));

		ui.showModal(u ? _('Edit user %s').format(hs.h(u.name)) : _('Add user'), body);
	},

	reset: function(u) {
		return hs.userReset(u.name).then(L.bind(this.refresh, this));
	},

	remove: function(u) {
		return ui.showModal(_('Delete %s?').format(hs.h(u.name)), [
			E('p', _('The user is deleted and logged out.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', {
					'class': 'btn cbi-button-negative',
					'click': ui.createHandlerFn(this, function() {
						return hs.userRemove(u.name).then(ui.hideModal).then(L.bind(this.refresh, this));
					})
				}, _('Delete'))
			])
		]);
	},

	render: function(data) {
		var table = E('table', { 'class': 'table', 'id': 'hs-users' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				_('Name'), _('Profile'), _('Server'), _('MAC'), _('Limits'), _('Used'), _('State'), _('Comment'), ''
			].map(function(t) { return E('th', { 'class': 'th' }, t); }))
		]);

		cbi_update_table(table, this.rows(data[0].users || []), E('em', _('No users yet')));

		var search = E('input', { 'id': 'hs-user-search', 'class': 'cbi-input-text', 'type': 'search', 'placeholder': _('Search name, comment, batch') });
		var timer = null;
		search.addEventListener('input', L.bind(function() {
			window.clearTimeout(timer);
			timer = window.setTimeout(L.bind(this.refresh, this), 300);
		}, this));

		var count = E('div', { 'id': 'hs-user-count', 'class': 'cbi-value-description' });
		window.setTimeout(L.bind(this.showCount, this, data[0]), 0);

		return E('div', {}, [
			E('h2', _('Hotspot users')),
			E('div', { 'class': 'cbi-map-descr' }, _('Local accounts (MikroTik /ip hotspot user). Users unknown here are tried against RADIUS when a server profile uses RADIUS.')),
			E('div', { 'class': 'cbi-section' }, [
				search, count,
				table,
				E('div', { 'class': 'cbi-section-create' }, [
					E('button', { 'class': 'btn cbi-button-add', 'click': ui.createHandlerFn(this, 'edit', null) }, _('Add user'))
				])
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
