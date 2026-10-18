'use strict';
'require view';
'require form';
'require uci';
'require tools.wrthotspot as hs';

return view.extend({
	load: function() {
		return uci.load('wrthotspot');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('wrthotspot', _('Hotspot settings'));

		s = m.section(form.NamedSection, 'global', 'global');
		s.tab('general', _('General'));
		s.tab('https', _('HTTPS'));
		s.tab('shaping', _('Rate limiting'));
		s.tab('advanced', _('Advanced'));

		o = s.taboption('general', form.Flag, 'enabled', _('Enable hotspot'),
			_('Disabling removes all hotspot restrictions from the network.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'portal_port', _('Portal port'));
		o.datatype = 'port';
		o.placeholder = '8002';

		o = s.taboption('general', form.Value, 'poll_interval', _('Check interval'),
			_('How often counters, timeouts, limits and bursts are evaluated.'));
		o.placeholder = '10s';
		o.validate = hs.validateDuration;

		o = s.taboption('general', form.ListValue, 'log_level', _('Log level'));
		[ 'error', 'warn', 'info', 'debug' ].forEach(function(l) { o.value(l); });
		o.default = 'info';

		o = s.taboption('https', form.Value, 'https_port', _('HTTPS port'));
		o.datatype = 'port';
		o.placeholder = '8003';

		o = s.taboption('https', form.Value, 'ssl_certificate', _('Certificate'),
			_('PEM or DER. <code>wrthotspot cert &lt;dns-name&gt;</code> creates a self-signed one for testing; use a real certificate (e.g. ACME) in production.'));
		o.placeholder = '/etc/wrthotspot/portal.crt';

		o = s.taboption('https', form.Value, 'ssl_key', _('Private key'));
		o.placeholder = '/etc/wrthotspot/portal.key';

		o = s.taboption('shaping', form.ListValue, 'shaper', _('Rate limiting'),
			_('HTB shaping needs the <em>wrt-hotspot-shaper</em> package; otherwise traffic is policed by nftables.'));
		o.value('auto', _('automatic'));
		o.value('tc', _('tc HTB shaping'));
		o.value('nft', _('nftables policing'));
		o.value('off', _('off'));
		o.default = 'auto';

		o = s.taboption('shaping', form.Value, 'shaper_capacity', _('Shaper capacity'),
			_('Root rate of the HTB trees; keep it above the real link speed.'));
		o.placeholder = '10G';

		o = s.taboption('advanced', form.Value, 'db_sync_interval', _('Flash write interval'),
			_('Users\' usage counters and cookies are written to flash this often.'));
		o.placeholder = '5m';
		o.validate = hs.validateDuration;

		o = s.taboption('advanced', form.Value, 'resolve_interval', _('Walled garden resolve interval'));
		o.placeholder = '5m';
		o.validate = hs.validateDuration;

		o = s.taboption('advanced', form.Value, 'walled_garden_ttl', _('Walled garden address lifetime'));
		o.placeholder = '1h';
		o.validate = hs.validateDuration;

		o = s.taboption('advanced', form.Value, 'state_dir', _('State directory'));
		o.placeholder = '/tmp/wrthotspot';

		o = s.taboption('advanced', form.Value, 'db_dir', _('Database directory'));
		o.placeholder = '/etc/wrthotspot';

		return m.render();
	}
});
