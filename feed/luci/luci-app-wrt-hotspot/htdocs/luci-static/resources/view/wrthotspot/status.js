'use strict';
'require view';
'require poll';
'require ui';
'require dom';
'require rpc';
'require tools.wrthotspot as hs';

var callDHCPLeases = rpc.declare({ object: 'luci-rpc', method: 'getDHCPLeases' });
var PAGE_SIZE = 100;

function dhcpHostnames(leases) {
	var byMac = Object.create(null);
	var byIPv6 = Object.create(null);

	(leases.dhcp_leases || []).forEach(function(lease) {
		if (lease.hostname && lease.hostname != '*' && lease.macaddr)
			byMac[String(lease.macaddr).toLowerCase()] = lease.hostname;
	});

	(leases.dhcp6_leases || []).forEach(function(lease) {
		if (!lease.hostname || lease.hostname == '*')
			return;

		var addresses = lease.ip6addrs || (lease.ip6addr ? [ lease.ip6addr ] : []);
		addresses.forEach(function(address) {
			byIPv6[String(address).split('/')[0].toLowerCase()] = lease.hostname;
		});
	});

	return { byMac: byMac, byIPv6: byIPv6 };
}

function header(titles) {
	return E('tr', { 'class': 'tr table-titles' }, titles.map(function(t) {
		return E('th', { 'class': 'th' }, t);
	}));
}

return view.extend({
	load: function() {
		return hs.status();
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

		return E('div', { 'class': 'hs-metrics' }, tiles.map(function(t) {
			return E('div', { 'class': 'hs-metric' }, [
				E('span', { 'class': 'hs-metric-label' }, t[0]),
				E('strong', { 'class': 'hs-metric-value' }, hs.h(t[1]))
			]);
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

	hostRows: function(hosts, leases) {
		var names = dhcpHostnames(leases || {});

		return hosts.map(function(h) {
			var hostname = names.byMac[String(h.mac || '').toLowerCase()];

			if (!hostname)
				(h.ipv6 || []).some(function(address) {
					hostname = names.byIPv6[String(address).split('/')[0].toLowerCase()];
					return !!hostname;
				});

			return [
				hs.h(h.mac),
				hs.h(hostname || '-'),
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

	pageControls: function(prefix, offset, shown, total) {
		var range = document.getElementById(prefix + '-range');
		var previous = document.getElementById(prefix + '-previous');
		var next = document.getElementById(prefix + '-next');

		range.textContent = total ? _('%d-%d of %d').format(offset + 1, offset + shown, total) : _('No entries');
		previous.disabled = offset === 0;
		next.disabled = !shown || offset + shown >= total;
	},

	pageButtons: function(prefix, field) {
		var previous = E('button', { 'id': prefix + '-previous', 'class': 'btn', 'disabled': '' }, _('Previous'));
		var next = E('button', { 'id': prefix + '-next', 'class': 'btn', 'disabled': '' }, _('Next'));

		previous.addEventListener('click', L.bind(function() {
			this[field] = Math.max(0, this[field] - PAGE_SIZE);
			return this.refresh();
		}, this));
		next.addEventListener('click', L.bind(function() {
			this[field] += PAGE_SIZE;
			return this.refresh();
		}, this));

		return E('div', { 'class': 'cbi-value' }, [
			previous, ' ', E('span', { 'id': prefix + '-range' }, _('Loading…')), ' ', next
		]);
	},

	refresh: function(status) {
		var seq = this.refreshSeq = (this.refreshSeq || 0) + 1;
		var sessionOffset = this.sessionOffset;
		var hostOffset = this.hostOffset;

		return Promise.all([ status || hs.status(), hs.sessions(sessionOffset, PAGE_SIZE, ''),
			hs.hosts(hostOffset, PAGE_SIZE, ''), hs.cookies(),
			L.resolveDefault(callDHCPLeases(), {}) ]).then(L.bind(function(data) {
			if (seq !== this.refreshSeq)
				return;

			var summary = data[0] || {};
			var sessions = data[1] || [];
			var hosts = data[2] || [];
			if ((!sessions.length && sessionOffset > 0) || (!hosts.length && hostOffset > 0)) {
				if (!sessions.length && sessionOffset > 0)
					this.sessionOffset = Math.max(0, Math.ceil((summary.sessions || 0) / PAGE_SIZE) - 1) * PAGE_SIZE;
				if (!hosts.length && hostOffset > 0)
					this.hostOffset = Math.max(0, Math.ceil((summary.hosts || 0) / PAGE_SIZE) - 1) * PAGE_SIZE;
				if (this.sessionOffset !== sessionOffset || this.hostOffset !== hostOffset)
					return this.refresh(summary);
			}

			dom.content(document.getElementById('hs-summary'), this.renderSummary(summary));
			cbi_update_table('#hs-sessions', this.sessionRows(sessions), E('em', _('No active sessions')));
			this.pageControls('hs-sessions', sessionOffset, sessions.length, summary.sessions || 0);

			var leases = data[4] || {};
			var hostKey = JSON.stringify([
				hosts.map(function(h) { return [ h.mac, h.authorized, h.server, h.dev, h.ipv4, h.ipv6 ]; }),
				(leases.dhcp_leases || []).map(function(l) { return [ l.macaddr, l.hostname ]; }),
				(leases.dhcp6_leases || []).map(function(l) { return [ l.ip6addr, l.ip6addrs, l.hostname ]; })
			]);
			if (hostKey !== this.hostKey) {
				cbi_update_table('#hs-hosts', this.hostRows(hosts, leases), E('em', _('No hosts seen')));
				this.hostKey = hostKey;
			}
			this.pageControls('hs-hosts', hostOffset, hosts.length, summary.hosts || 0);

			cbi_update_table('#hs-cookies', this.cookieRows(data[3] || {}), E('em', _('No cookies')));
		}, this));
	},

	render: function(data) {
		this.sessionOffset = 0;
		this.hostOffset = 0;
		var view = E('div', {}, [
			E('h2', _('Hotspot')),
			E('div', { 'class': 'cbi-map-descr' }, _('Live state of the captive portal: logged-in sessions (MikroTik "active"), every device seen on hotspot interfaces ("hosts") and remembered logins ("cookies").')),
			E('div', { 'class': 'cbi-section' }, [ E('h3', _('Overview')), E('div', { 'id': 'hs-summary' }) ]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Active sessions')),
				E('div', { 'class': 'hs-table-scroll' }, E('table', { 'class': 'table', 'id': 'hs-sessions' }, [
					header([ _('User'), _('MAC'), _('IPv4'), _('IPv6'), _('Server'), _('Login by'), _('Uptime'),
						_('Time left'), _('Up / down'), _('Rate limit'), '' ])
				])),
				this.pageButtons('hs-sessions', 'sessionOffset')
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Hosts')),
				E('div', { 'class': 'hs-table-scroll' }, E('table', { 'class': 'table', 'id': 'hs-hosts' }, [
					header([ _('MAC'), _('DHCP hostname'), _('State'), _('Server'), _('Device'), _('IPv4'), _('IPv6') ])
				])),
				this.pageButtons('hs-hosts', 'hostOffset')
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Cookies')),
				E('div', { 'class': 'hs-table-scroll' }, E('table', { 'class': 'table', 'id': 'hs-cookies' }, [
					header([ _('Type'), _('User'), _('MAC'), _('Expires in'), '' ])
				]))
			])
		]);

		requestAnimationFrame(L.bind(function() {
			dom.content(document.getElementById('hs-summary'), this.renderSummary(data || {}));
			this.refresh(data);
		}, this));

		poll.add(L.bind(function() { return this.refresh(); }, this), 15);

		return hs.wrap(view);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
