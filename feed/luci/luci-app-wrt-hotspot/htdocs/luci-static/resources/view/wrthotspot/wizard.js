'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require tools.wrthotspot as hs';

var STEP = Math.max(1, Math.min(3, +(new URLSearchParams(window.location.search).get('step') || 1)));

function stepUrl(n) {
	return L.url('admin/services/wrthotspot/wizard') + '?step=' + n;
}

function navigation() {
	return E('div', { 'class': 'cbi-section' }, [
		E('p', {}, _('Set up a hotspot in three steps. Save and Apply each page before continuing. The network interface and Wi-Fi SSID must already exist.')),
		E('p', {}, [
			E('a', { 'href': stepUrl(1), 'class': 'btn ' + (STEP == 1 ? 'cbi-button-action' : '') }, _('1. Network')), ' ',
			E('a', { 'href': stepUrl(2), 'class': 'btn ' + (STEP == 2 ? 'cbi-button-action' : '') }, _('2. Login page')), ' ',
			E('a', { 'href': stepUrl(3), 'class': 'btn ' + (STEP == 3 ? 'cbi-button-action' : '') }, _('3. User limits'))
		])
	]);
}

function sectionByName(type, name) {
	var found = uci.sections('wrthotspot', type).filter(function(s) { return s.name == name; });
	return found.length ? found[0]['.name'] : null;
}

return view.extend({
	load: function() {
		return Promise.all([ uci.load('wrthotspot'), uci.load('network') ]);
	},

	render: function() {
		var m, s, o, id;
		var content;

		if (STEP == 1) {
			this.handleSave = null;
			this.handleSaveApply = null;
			this.handleReset = null;
			var nets = uci.sections('network', 'interface').map(function(n) { return n['.name']; })
				.filter(function(n) { return [ 'loopback', 'wan', 'wan6' ].indexOf(n) < 0; });
			var choices = {};
			nets.forEach(function(n) { choices[n] = n; });
			var select = new ui.Select(nets[0], choices, { sort: true });
			content = E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Choose a hotspot network')),
				E('p', {}, _('Save and Apply creates a hotspot server, firewall zone and rules, DHCP service when needed, and forwarding to WAN. It also disables flow offloading so traffic accounting works.')),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Network')),
					E('div', { 'class': 'cbi-value-field' }, select.render())
				]),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn cbi-button-apply', 'click': ui.createHandlerFn(this, function() {
						var net = select.getValue();
						if (!net)
							return ui.addNotification(null, E('p', _('Choose a network first.')), 'warning');
						return hs.setup(net).then(function(res) {
							if (!res || res.ok === false)
								return ui.addNotification(null, E('p', hs.h(res && res.error || _('Setup failed'))), 'danger');
							ui.addNotification(null, E('pre', hs.h(res.output || _('Settings applied'))), 'info');
						});
					}) }, _('Save and Apply'))
				])
			]);
		}
		else if (STEP == 2) {
			id = sectionByName('server_profile', 'default');
			if (!id)
				content = E('p', {}, _('The default server profile is missing. Create one on the Servers page.'));
			else {
				m = new form.Map('wrthotspot', _('Portal and login'), _('These settings apply to servers using the default server profile. Save and Apply before moving to user limits.'));
				s = m.section(form.NamedSection, id, 'server_profile');
				o = s.option(form.Value, 'dns_name', _('Portal DNS name'), _('Required for HTTPS login and captive portal announcements. Leave empty for an IP address based portal.'));
				o.datatype = 'hostname';
				o.placeholder = 'login.wifi';
				o = s.option(form.MultiValue, 'login_by', _('Login methods'));
				hs.loginMethods.forEach(function(method) { o.value(method[0], method[1]); });
				o.rmempty = false;
				o = s.option(form.Value, 'html_directory', _('Login page set'));
				o.value('/usr/share/wrthotspot/pages/default', _('Default'));
				o.value('/usr/share/wrthotspot/pages/classic', _('Classic'));
				o = s.option(form.Flag, 'rfc8910', _('Announce captive portal (RFC 8910)'));
				content = m.render();
			}
		}
		else {
			id = sectionByName('user_profile', 'default');
			if (!id)
				content = E('p', {}, _('The default user profile is missing. Create one on the User Profiles page.'));
			else {
				m = new form.Map('wrthotspot', _('Default user limits'), _('These limits apply to users assigned the default profile. Leave a limit empty for no limit.'));
				s = m.section(form.NamedSection, id, 'user_profile');
				o = s.option(form.Value, 'shared_users', _('Devices per user'));
				o.validate = function(section, value) { return value == 'unlimited' || /^[1-9][0-9]*$/.test(value) ? true : _('Enter a positive number or unlimited'); };
				o = s.option(form.Value, 'rate_limit', _('Upload/download rate limit'), hs.rateLimitHelp);
				o.placeholder = '2M/10M';
				o.validate = hs.validateRateLimit;
				o = s.option(form.Value, 'session_timeout', _('Session timeout'));
				o.validate = hs.validateDuration;
				content = m.render();
			}
		}

		return Promise.resolve(content).then(function(node) {
			return E('div', {}, [
				E('h2', _('Hotspot Quick Setup')),
				navigation(),
				node,
				E('p', {}, STEP == 3 ? [
					E('a', { 'href': L.url('admin/services/wrthotspot/users') }, _('Add users')), ' · ',
					E('a', { 'href': L.url('admin/services/wrthotspot/diagnostics') }, _('Check hotspot'))
				] : E('a', { 'href': stepUrl(STEP + 1) }, _('Next step →')))
			]);
		});
	}
});
