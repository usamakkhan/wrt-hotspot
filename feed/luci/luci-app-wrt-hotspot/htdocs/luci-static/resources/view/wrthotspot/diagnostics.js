'use strict';
'require view';
'require ui';
'require uci';
'require dom';
'require tools.wrthotspot as hs';

var BADGE = {
	ok: [ 'success', _('OK') ],
	info: [ 'notice', _('Info') ],
	warn: [ 'warning', _('Warning') ],
	error: [ 'danger', _('Error') ]
};

return view.extend({
	load: function() {
		return Promise.all([ hs.check(), uci.load('wrthotspot'), uci.load('network') ]);
	},

	setup: function(net) {
		return hs.setup(net).then(L.bind(function(res) {
			if (res && res.ok === false)
				return ui.addNotification(null, E('p', res.error), 'danger');

			ui.addNotification(null, E('pre', res.output || _('Done')), 'info');

			// Network, firewall and DHCP reload in the background.
			return new Promise(function(resolve) { window.setTimeout(resolve, 6000); }).then(L.bind(this.refresh, this));
		}, this));
	},

	fix: function(action) {
		if (action == 'disable_offload') {
			var net = uci.sections('wrthotspot', 'server').map(function(s) { return s.interface; }).filter(Boolean)[0];
			return net ? this.setup(net) : ui.addNotification(null, E('p', _('Add a hotspot server first.')), 'warning');
		}

		if (/^setup:/.test(action))
			return this.setup(action.substr(6));
	},

	flush: function() {
		return ui.showModal(_('Log everybody out?'), [
			E('p', _('All sessions end and the hotspot rules are removed until the next reload.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', {
					'class': 'btn cbi-button-negative',
					'click': ui.createHandlerFn(this, function() {
						return hs.flush().then(hs.reload).then(ui.hideModal).then(L.bind(this.refresh, this));
					})
				}, _('Log everybody out'))
			])
		]);
	},

	rows: function(checks) {
		return checks.map(L.bind(function(c) {
			var b = BADGE[c.level] || BADGE.info;
			var fix = c.fix ? E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, 'fix', c.fix) },
				/^setup:/.test(c.fix) ? _('Set up %s').format(c.fix.substr(6)) : _('Fix')) : '';

			return [ E('span', { 'class': 'label ' + b[0] }, b[1]), hs.h(c.message), fix ];
		}, this));
	},

	refresh: function() {
		return hs.check().then(L.bind(function(checks) {
			cbi_update_table('#hs-checks', this.rows(checks), E('em', _('No result')));
		}, this));
	},

	render: function(data) {
		var table = E('table', { 'class': 'table', 'id': 'hs-checks' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th', 'style': 'width:7em' }, _('State')), E('th', { 'class': 'th' }, _('Check')), E('th', { 'class': 'th' }, '')
			])
		]);

		cbi_update_table(table, this.rows(data[0] || []), E('em', _('hotspotd is not running')));

		// Plain select: the CBI NetworkSelect widget only works inside a form section.
		var nets = uci.sections('network', 'interface').map(function(s) { return s['.name']; })
			.filter(function(n) { return [ 'loopback', 'wan', 'wan6' ].indexOf(n) < 0; });
		var choices = {};
		nets.forEach(function(n) { choices[n] = n; });
		var netsel = new ui.Select(nets[0], choices, { sort: true });

		return E('div', {}, [
			E('h2', _('Hotspot diagnostics')),
			E('div', { 'class': 'cbi-section' }, [
				table,
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'refresh') }, _('Check again')), ' ',
					E('button', { 'class': 'btn cbi-button-negative', 'click': ui.createHandlerFn(this, 'flush') }, _('Log everybody out'))
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Set up a hotspot network')),
				E('p', _('Creates the firewall zone with the portal, DNS and DHCP rules, forwarding to wan, DHCP/RA service, a hotspot server, and switches flow offloading off. The network itself (bridge, Wi-Fi SSID) must exist.')),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Network')),
					E('div', { 'class': 'cbi-value-field' }, netsel.render())
				]),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'btn cbi-button-apply',
						'click': ui.createHandlerFn(this, function() {
							var net = netsel.getValue();
							return net ? this.setup(net) : ui.addNotification(null, E('p', _('Choose a network')), 'warning');
						})
					}, _('Set up'))
				])
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
