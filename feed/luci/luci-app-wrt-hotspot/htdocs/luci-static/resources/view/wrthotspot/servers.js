'use strict';
'require view';
'require form';
'require uci';
'require tools.widgets as widgets';
'require tools.wrthotspot as hs';

function profileNames(type) {
	return uci.sections('wrthotspot', type).map(function(s) { return s.name || s['.name']; });
}

function uniqueName(type) {
	return function(section_id, value) {
		if (!value)
			return _('A name is required');

		if (!/^[A-Za-z0-9_.-]+$/.test(value))
			return _('Use letters, digits, ".", "_" and "-"');

		var dup = uci.sections('wrthotspot', type).filter(function(s) {
			return s['.name'] != section_id && (s.name || s['.name']) == value;
		});

		return dup.length ? _('Name already used') : true;
	};
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('wrthotspot'),
			L.resolveDefault(hs.status(), {})
		]);
	},

	render: function(data) {
		var m, s, o;
		// RADIUS options only when wrt-hotspot-radius is installed (unknown: show them).
		var hasRadius = (data[1] || {}).radius !== false;

		m = new form.Map('wrthotspot', _('Hotspot servers'),
			_('One hotspot server per network (MikroTik /ip hotspot). Clients on that network must log in. The easiest start is <code>wrthotspot setup &lt;network&gt;</code> or the Diagnostics tab, which also create the firewall zone, rules and DHCP.'));

		s = m.section(form.GridSection, 'server', _('Servers'));
		s.addremove = true;
		s.anonymous = false;
		s.nodescriptions = true;
		s.addbtntitle = _('Add server');

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.editable = true;

		o = s.option(widgets.NetworkSelect, 'interface', _('Network'));
		o.nocreate = true;
		o.rmempty = false;

		o = s.option(form.ListValue, 'profile', _('Server profile'));
		profileNames('server_profile').forEach(function(n) { o.value(n); });
		o.default = 'default';

		o = s.option(form.Value, 'idle_timeout', _('Idle timeout'), _('Unauthorized hosts are forgotten after this inactivity.'));
		o.placeholder = '5m';
		o.validate = hs.validateDuration;

		o = s.option(form.Value, 'keepalive_timeout', _('Keepalive timeout'));
		o.placeholder = _('none');
		o.validate = hs.validateDuration;
		o.modalonly = true;

		o = s.option(form.Value, 'login_timeout', _('Login timeout'));
		o.placeholder = _('none');
		o.validate = hs.validateDuration;
		o.modalonly = true;

		/* server profiles */

		s = m.section(form.GridSection, 'server_profile', _('Server profiles'),
			_('How users log in (MikroTik /ip hotspot profile).'));
		s.addremove = true;
		s.anonymous = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add server profile');
		s.sectiontitle = function(section_id) {
			return uci.get('wrthotspot', section_id, 'name') || section_id;
		};

		s.tab('general', _('General'));
		s.tab('trial', _('Trial'));
		if (hasRadius)
			s.tab('radius', _('RADIUS'));

		o = s.taboption('general', form.Value, 'name', _('Name'));
		o.rmempty = false;
		o.validate = uniqueName('server_profile');
		o.modalonly = true;	// the grid's title column already shows it

		o = s.taboption('general', form.Value, 'dns_name', _('DNS name'),
			_('Portal host name, answered by the router on each hotspot network. Needed for HTTPS and RFC 8908/8910.'));
		o.placeholder = 'login.wifi';
		o.datatype = 'hostname';

		o = s.taboption('general', form.MultiValue, 'login_by', _('Login by'));
		hs.loginMethods.forEach(function(lm) { o.value(lm[0], lm[1]); });
		o.default = 'http-chap cookie';
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'http_cookie_lifetime', _('HTTP cookie lifetime'));
		o.placeholder = '3d';
		o.validate = hs.validateDuration;
		o.modalonly = true;

		o = s.taboption('general', form.Value, 'mac_auth_password', _('MAC auth password'),
			_('Password sent for MAC logins (some RADIUS servers reject empty ones).'));
		o.password = true;
		o.modalonly = true;

		o = s.taboption('general', form.Value, 'html_directory', _('Page directory'),
			_('Login pages; MikroTik hotspot page sets work unmodified.'));
		o.placeholder = '/usr/share/wrthotspot/pages/default';
		o.modalonly = true;

		o = s.taboption('general', form.Flag, 'split_user_domain', _('Split user domain'),
			_('Strip user@domain / domain\\user to the user part.'));
		o.modalonly = true;

		o = s.taboption('general', form.Flag, 'rfc8910', _('Announce captive portal (RFC 8910)'),
			_('DHCP option 114 and RA/DHCPv6 captive-portal URI; needs a DNS name and a certificate.'));
		o.default = '1';
		o.modalonly = true;

		o = s.taboption('trial', form.Value, 'trial_uptime_limit', _('Trial uptime'));
		o.placeholder = '30m';
		o.validate = hs.validateDuration;
		o.modalonly = true;

		o = s.taboption('trial', form.Value, 'trial_uptime_reset', _('Trial again after'));
		o.placeholder = '1d';
		o.validate = hs.validateDuration;
		o.modalonly = true;

		o = s.taboption('trial', form.ListValue, 'trial_user_profile', _('Trial user profile'));
		profileNames('user_profile').forEach(function(n) { o.value(n); });
		o.default = 'default';
		o.modalonly = true;

		if (hasRadius) {
			o = s.taboption('radius', form.Flag, 'use_radius', _('Use RADIUS'),
				_('Unknown users are authenticated by the RADIUS servers (local users are checked first).'));

			o = s.taboption('radius', form.Flag, 'radius_accounting', _('Accounting'));
			o.default = '1';
			o.depends('use_radius', '1');
			o.modalonly = true;

			o = s.taboption('radius', form.Value, 'radius_interim_update', _('Interim update'),
				_('<code>received</code> = use Acct-Interim-Interval from the server, or a duration.'));
			o.placeholder = 'received';
			o.depends('use_radius', '1');
			o.modalonly = true;

			o = s.taboption('radius', form.ListValue, 'radius_mac_format', _('MAC format'));
			[ 'XX:XX:XX:XX:XX:XX', 'xx:xx:xx:xx:xx:xx', 'XX-XX-XX-XX-XX-XX', 'xx-xx-xx-xx-xx-xx', 'XXXXXXXXXXXX', 'xxxxxxxxxxxx', 'XXXX.XXXX.XXXX', 'xxxx.xxxx.xxxx' ]
				.forEach(function(f) { o.value(f); });
			o.depends('use_radius', '1');
			o.modalonly = true;

			o = s.taboption('radius', form.ListValue, 'nas_port_type', _('NAS-Port-Type'));
			[ 'wireless-802.11', 'ethernet', 'virtual', 'async', 'sync' ].forEach(function(t) { o.value(t); });
			o.depends('use_radius', '1');
			o.modalonly = true;

			o = s.taboption('radius', form.Value, 'radius_location_id', _('WISPr location ID'));
			o.depends('use_radius', '1');
			o.modalonly = true;

			o = s.taboption('radius', form.Value, 'radius_location_name', _('WISPr location name'));
			o.depends('use_radius', '1');
			o.modalonly = true;
		}

		return m.render();
	}
});
