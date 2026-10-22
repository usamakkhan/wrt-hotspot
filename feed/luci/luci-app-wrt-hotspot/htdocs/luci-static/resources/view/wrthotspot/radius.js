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

		m = new form.Map('wrthotspot', _('RADIUS'),
			_('Servers are tried in order with retries and failover. Turn RADIUS on per server profile ("Servers" tab). Every request carries a Message-Authenticator.'));

		s = m.section(form.GridSection, 'radius', _('Servers'));
		s.addremove = true;
		s.anonymous = false;
		s.sortable = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add RADIUS server');

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.editable = true;

		o = s.option(form.Value, 'address', _('Address'));
		o.datatype = 'ipaddr';
		o.rmempty = false;

		o = s.option(form.Value, 'secret', _('Secret'));
		o.password = true;
		o.rmempty = false;
		o.modalonly = true;

		o = s.option(form.Value, 'auth_port', _('Auth port'));
		o.datatype = 'port';
		o.placeholder = '1812';

		o = s.option(form.Value, 'acct_port', _('Accounting port'));
		o.datatype = 'port';
		o.placeholder = '1813';

		o = s.option(form.Value, 'timeout', _('Timeout'), _('Per attempt, e.g. 1100ms or 2s.'));
		o.placeholder = '1100ms';
		o.validate = function(section_id, value) {
			return (!value || /^[0-9]+(ms|s)?$/.test(value)) ? true : _('e.g. 1100ms or 2s');
		};
		o.modalonly = true;

		o = s.option(form.Value, 'retries', _('Retries'));
		o.datatype = 'range(0,10)';
		o.placeholder = '2';
		o.modalonly = true;

		o = s.option(form.Flag, 'require_message_auth', _('Require Message-Authenticator'),
			_('Reject replies without it (BlastRADIUS, CVE-2024-3596). Turn off only for servers that cannot send one.'));
		o.default = '1';
		o.modalonly = true;

		s = m.section(form.NamedSection, 'global', 'global', _('NAS settings'));

		o = s.option(form.Value, 'nas_identifier', _('NAS-Identifier'));
		o.placeholder = 'WrtHotspot';

		o = s.option(form.Value, 'coa_port', _('CoA / Disconnect port'),
			_('RFC 5176 listener, 0 to disable. Allow this UDP port from a RADIUS server outside the router in the firewall.'));
		o.datatype = 'or("0", port)';
		o.placeholder = '3799';

		return hs.wrap(m.render());
	}
});
