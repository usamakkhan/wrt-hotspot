'use strict';
'require view';
'require form';
'require uci';

return view.extend({
	load: function() {
		return uci.load('wrthotspot');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('wrthotspot', _('IP bindings'),
			_('Devices that skip the login (bypassed) or get no access at all (blocked), by MAC, address/prefix or MAC + address. Devices change IPv6 addresses (privacy extensions): bind them by MAC.'));

		s = m.section(form.GridSection, 'ip_binding');
		s.addremove = true;
		s.anonymous = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add binding');

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.editable = true;

		o = s.option(form.ListValue, 'type', _('Type'));
		o.value('bypassed', _('bypassed'));
		o.value('blocked', _('blocked'));
		o.value('regular', _('regular'));
		o.default = 'bypassed';

		o = s.option(form.Value, 'mac', _('MAC address'));
		o.datatype = 'macaddr';

		o = s.option(form.Value, 'address', _('Address'), _('Single address when combined with a MAC.'));
		o.datatype = 'or(ip4addr, ip6addr, cidr4, cidr6)';

		o = s.option(form.ListValue, 'server', _('Server'));
		o.value('all', _('all'));
		uci.sections('wrthotspot', 'server').forEach(function(sv) { o.value(sv['.name']); });
		o.default = 'all';

		o = s.option(form.Value, 'comment', _('Comment'));

		s.validate = function(section_id) {
			var mac = this.formvalue(section_id, 'mac'), addr = this.formvalue(section_id, 'address');

			if (!mac && !addr)
				return _('A binding needs a MAC address or an address');

			// Same rules as hotspotd, which would otherwise drop the binding.
			if (addr && /\/.*\./.test(addr))
				return _('Use a prefix length (10.0.0.0/24), not a netmask');

			if (mac && addr && addr.indexOf('/') >= 0)
				return _('With a MAC address, give a single address, not a prefix');

			return true;
		};

		return m.render();
	}
});
