'use strict';
'require view';
'require poll';
'require ui';
'require dom';
'require tools.wrthotspot as hs';

function cell(content, cls) {
	return E('td', { 'class': 'td' + (cls ? ' ' + cls : '') }, content);
}

function header(titles) {
	return E('tr', { 'class': 'tr table-titles' }, titles.map(function(t) {
		return E('th', { 'class': 'th' }, t);
	}));
}

return view.extend({
	load: function() {
		return Promise.all([ hs.status(), hs.sessions(), hs.hosts(), hs.cookies() ]);
	},

	logout: function(s, ev) {
		return ui.showModal(_('Log out %s?').format(hs.h(s.user)), [
			E('p', _('The device %s loses access immediately.').format(hs.h(s.mac))),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', {
					'class': 'btn cbi-button-negative',
					'click': ui.createHandlerFn(this, function() {
						return hs.logout(undefined, undefined, s.id, 'admin-reset').then(ui.hideModal).then(this.refresh.bind(this));
					})
				}, _('Log out'))
			])
		]);
	},

	removeCookie: function(c) {
		return hs.cookieRemove(c.mac, undefined).then(this.refresh.bind(this));
	},

	renderSummary: function(st) {
		var devs = Object.keys(st.devices || {}).map(function(d) { return '%s (%s)'.format(st.devices[d], d); });
		var shaper = { tc: _('tc HTB shaping'), nft: _('nftables policing'), off: _('off') }[st.shaper] || '-';

		var tiles = [
			[ _('Active sessions'), st.sessions ],
			[ _('Hosts'), st.hosts ],
			[ _('Local users'), st.users ],
			[ _('Hotspot servers'), devs.length ? devs.join(', ') : _('none active') ],
			[ _('Rate limiting'), shaper ],
			[ _('Version'), st.version ]
		];

		if (st.radius_backlog)
			tiles.push([ _('Queued RADIUS accounting'), st.radius_backlog ]);

		return E('table', { 'class': 'table' }, tiles.map(function(t) {
			return E('tr', { 'class': 'tr' }, [ cell(E('strong', t[0]), 'left'), cell(String(t[1])) ]);
		}));
	},

	sessionRows: function(sessions) {
		return sessions.map(L.bind(function(s) {
			var left = (s.session_time_left != null) ? hs.fmtDuration(s.session_time_left) : '∞';
			var rate = s.rate_limit || '-';

			if (s.bursting && s.rate_limit && /\s/.test(s.rate_limit))
				rate += (s.bursting.tx ? ' ⇡' : '');

			return [
				E('span', { 'title': s.id }, hs.h(s.user)),
				hs.h(s.mac),
				hs.h((s.ipv4 || []).join(', ') || '-'),
				E('span', { 'title': (s.ipv6 || []).join('\n') }, (s.ipv6 || []).length ? _('%d addr.').format(s.ipv6.length) : '-'),
				hs.h(s.server),
				hs.h(s.login_by + (s.auth == 'radius' ? ' (RADIUS)' : '')),
				hs.fmtDuration(s.uptime),
				left,
				hs.fmtBytes(s.bytes_in) + ' / ' + hs.fmtBytes(s.bytes_out),
				hs.h(rate),
				E('button', { 'class': 'btn cbi-button-negative', 'click': ui.createHandlerFn(this, 'logout', s) }, _('Log out'))
			];
		}, this));
	},

	hostRows: function(hosts) {
		return hosts.map(function(h) {
			return [
				hs.h(h.mac),
				h.authorized ? E('span', { 'class': 'label success' }, _('logged in')) : _('not logged in'),
				hs.h(h.server || '-'),
				hs.h(h.dev || '-'),
				hs.h((h.ipv4 || []).join(', ') || '-'),
				E('span', { 'style': 'word-break:break-all' }, hs.h((h.ipv6 || []).join(' ') || '-'))
			];
		});
	},

	cookieRows: function(ck) {
		var rows = [];
		var self = this;

		(ck.cookies || []).forEach(function(c) {
			rows.push([ _('HTTP'), hs.h(c.user), hs.h(c.mac), hs.fmtDuration(c.expires_in),
				E('button', { 'class': 'btn cbi-button-remove', 'click': ui.createHandlerFn(self, 'removeCookie', c) }, _('Remove')) ]);
		});

		(ck.mac_cookies || []).forEach(function(c) {
			rows.push([ _('MAC'), hs.h(c.user), hs.h(c.mac), hs.fmtDuration(c.expires_in),
				E('button', { 'class': 'btn cbi-button-remove', 'click': ui.createHandlerFn(self, 'removeCookie', c) }, _('Remove')) ]);
		});

		return rows;
	},

	refresh: function() {
		return this.load().then(L.bind(function(data) {
			dom.content(document.getElementById('hs-summary'), this.renderSummary(data[0] || {}));
			cbi_update_table('#hs-sessions', this.sessionRows(data[1] || []), E('em', _('No active sessions')));
			cbi_update_table('#hs-hosts', this.hostRows(data[2] || []), E('em', _('No hosts seen')));
			cbi_update_table('#hs-cookies', this.cookieRows(data[3] || {}), E('em', _('No cookies')));
		}, this));
	},

	render: function(data) {
		var view = E('div', {}, [
			E('h2', _('Hotspot')),
			E('div', { 'class': 'cbi-map-descr' }, _('Live state of the captive portal: logged-in sessions (MikroTik "active"), every device seen on hotspot interfaces ("hosts") and remembered logins ("cookies").')),
			E('div', { 'class': 'cbi-section' }, [ E('h3', _('Overview')), E('div', { 'id': 'hs-summary' }) ]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Active sessions')),
				E('table', { 'class': 'table', 'id': 'hs-sessions' }, [
					header([ _('User'), _('MAC'), _('IPv4'), _('IPv6'), _('Server'), _('Login by'), _('Uptime'),
						_('Time left'), _('Up / down'), _('Rate limit'), '' ])
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Hosts')),
				E('table', { 'class': 'table', 'id': 'hs-hosts' }, [
					header([ _('MAC'), _('State'), _('Server'), _('Device'), _('IPv4'), _('IPv6') ])
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Cookies')),
				E('table', { 'class': 'table', 'id': 'hs-cookies' }, [
					header([ _('Type'), _('User'), _('MAC'), _('Expires in'), '' ])
				])
			])
		]);

		requestAnimationFrame(L.bind(function() {
			dom.content(document.getElementById('hs-summary'), this.renderSummary(data[0] || {}));
			cbi_update_table('#hs-sessions', this.sessionRows(data[1] || []), E('em', _('No active sessions')));
			cbi_update_table('#hs-hosts', this.hostRows(data[2] || []), E('em', _('No hosts seen')));
			cbi_update_table('#hs-cookies', this.cookieRows(data[3] || {}), E('em', _('No cookies')));
		}, this));

		poll.add(L.bind(this.refresh, this), 5);

		return view;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
