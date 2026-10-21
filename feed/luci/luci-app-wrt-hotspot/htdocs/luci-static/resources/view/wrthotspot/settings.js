'use strict';
'require view';
'require form';
'require uci';
'require tools.wrthotspot as hs';

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('wrthotspot'),
			L.resolveDefault(hs.status(), {})
		]);
	},

	render: function(data) {
		var m, s, o;
		var st = data[1] || {};
		var cap = st.capacity || {};
		var hasRadius = st.radius !== false;

		m = new form.Map('wrthotspot', _('Hotspot settings'));

		s = m.section(form.NamedSection, 'global', 'global');
		s.tab('general', _('General'));
		s.tab('capacity', _('Capacity'));
		s.tab('https', _('HTTPS'));
		s.tab('shaping', _('Rate limiting'));
		if (hasRadius)
			s.tab('billing', _('Billing integration'));
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

		o = s.taboption('general', form.Value, 'portal_max_requests', _('Concurrent portal requests'),
			_('Each one is a worker of about 0.4 MB. Empty = by RAM: 8 up to 64 MB, 16 up to 128 MB, 32 above.'));
		o.datatype = 'range(2,256)';
		o.placeholder = cap.portal_workers ? String(cap.portal_workers) : _('automatic');

		o = s.taboption('general', form.ListValue, 'lite', _('Lite mode'),
			_('For slow routers: each login and logout starts one process instead of up to four. Rate limits use nftables policing (no burst, priority or fair queuing), traffic of the last %s before a logout is not counted, and connections of logged-out clients expire on their own. Now: %s.').format(
				_('check interval'), st.lite ? _('on') : _('off')));
		o.value('auto', _('automatic (on up to 64 MB of RAM)'));
		o.value('1', _('on'));
		o.value('0', _('off'));
		o.default = 'auto';

		/* Capacity */

		o = s.taboption('capacity', form.DummyValue, '_capacity', _('This router'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			if (!cap.mode)
				return '<em>' + _('hotspotd is not running') + '</em>';
			if (cap.mode == 'off')
				return _('Capacity limits are off.');

			var warn = (cap.over_sessions || cap.over_users)
				? ' <strong style="color:#c00">' + _('above the recommended capacity') + '</strong>' : '';

			var why = '';
			if (cap.low_memory)
				why = '<br><strong>' + _('Little free memory: the minimum of %d sessions is allowed. The balanced or max mode fits more.').format(cap.auto_sessions) + '</strong>';
			else if (cap.limited_by == 'conntrack')
				why = '<br><small>' + _('Sessions limited by the connection tracking table (%d entries).').format(cap.conntrack_max) + '</small>';
			if (cap.low_flash)
				why += '<br><strong>' + _('Little free flash for the user database.') + '</strong>';

			return _('%s RAM tier, %s mode: %d / %d sessions, %d / %d user accounts.').format(
				(cap.tier || {}).label || '?', cap.mode, cap.sessions, cap.max_sessions, cap.users, cap.max_users) + warn +
				'<br><small>' + _('Reserve %s kept free, about %s per session.').format(
					hs.fmtBytes((cap.reserve_kb || 0) * 1024), hs.fmtBytes((cap.session_cost_kb || 0) * 1024)) + '</small>' + why;
		};

		o = s.taboption('capacity', form.ListValue, 'capacity', _('Capacity limits'),
			_('Limits computed from the router\'s RAM and flash keep enough memory free for routing and Wi-Fi.'));
		o.value('auto', _('automatic'));
		o.value('off', _('off (no limits)'));
		o.default = 'auto';

		o = s.taboption('capacity', form.ListValue, 'capacity_mode', _('Mode'),
			_('<em>safe</em>: largest free-memory buffer, fewer users, best performance. <em>balanced</em>: a middle way. <em>max</em>: most users, little headroom for heavy traffic.'));
		o.value('safe', _('safe'));
		o.value('balanced', _('balanced'));
		o.value('max', _('max'));
		o.default = 'safe';
		o.depends('capacity', 'auto');

		o = s.taboption('capacity', form.Value, 'max_sessions', _('Maximum sessions'),
			_('Replaces the computed value. Empty = automatic (%d now).').format(cap.auto_sessions || 0));
		o.datatype = 'uinteger';

		o = s.taboption('capacity', form.Value, 'max_users', _('Maximum user accounts'),
			_('Replaces the computed value. Empty = automatic (%d now). Admins can still add more after a warning.').format(cap.auto_users || 0));
		o.datatype = 'uinteger';

		o = s.taboption('capacity', form.Flag, 'capacity_override', _('Allow logins beyond the limit'),
			_('Clients are let in even when the router is full; this is logged as a warning.'));

		/* HTTPS */

		o = s.taboption('https', form.Value, 'https_port', _('HTTPS port'));
		o.datatype = 'port';
		o.placeholder = '8003';

		o = s.taboption('https', form.Value, 'ssl_certificate', _('Certificate'),
			_('PEM or DER. <code>wrthotspot cert &lt;dns-name&gt;</code> creates a self-signed one for testing; use a real certificate (e.g. ACME) in production.'));
		o.placeholder = '/etc/wrthotspot/portal.crt';

		o = s.taboption('https', form.Value, 'ssl_key', _('Private key'));
		o.placeholder = '/etc/wrthotspot/portal.key';

		/* Rate limiting */

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

		/* Billing integration (wrt-hotspot-radius) */

		if (hasRadius) {
			o = s.taboption('billing', form.ListValue, 'radius_preset', _('RADIUS server type'),
				_('How RADIUS requests look. <em>MikroTik</em> for servers that expect a RouterOS hotspot: SAS4, Radius Manager, Splynx, User Manager, daloRADIUS. <em>CoovaChilli</em> for RADIUSdesk, HotspotSystem and other UAM billing.'));
			o.value('mikrotik', _('MikroTik compatible'));
			o.value('coova', _('CoovaChilli compatible'));
			o.value('generic', _('Generic (RFC attributes only)'));
			o.default = 'mikrotik';

			o = s.taboption('billing', form.Flag, 'api_enable', _('RouterOS API'),
				_('Answers MikroTik API requests on TCP (online users, disconnect, hotspot users) for billing systems that manage the router that way, e.g. SAS4. Open the port in the firewall for the billing server only.'));

			o = s.taboption('billing', form.Value, 'api_port', _('API port'));
			o.datatype = 'port';
			o.placeholder = '8728';
			o.depends('api_enable', '1');

			o = s.taboption('billing', form.Value, 'api_user', _('API user'));
			o.depends('api_enable', '1');

			o = s.taboption('billing', form.Value, 'api_password', _('API password'),
				_('Hotspot admin operators can log in as well.'));
			o.password = true;
			o.depends('api_enable', '1');

			o = s.taboption('billing', form.DynamicList, 'api_allow', _('Allowed clients'),
				_('Addresses or networks that may connect. Empty = the RADIUS servers and the router itself.'));
			o.datatype = 'or(ipaddr,cidr)';
			o.depends('api_enable', '1');

			o = s.taboption('billing', form.Value, 'api_version', _('Reported RouterOS version'),
				_('Some billing systems pick their commands by version.'));
			o.placeholder = '7.16';
			o.depends('api_enable', '1');
		}

		/* Advanced */

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
