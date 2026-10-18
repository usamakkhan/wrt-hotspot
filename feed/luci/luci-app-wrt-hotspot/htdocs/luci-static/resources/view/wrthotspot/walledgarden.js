'use strict';
'require view';
'require form';
'require uci';

function serverOption(s) {
	var o = s.option(form.ListValue, 'server', _('Server'));
	o.value('all', _('all'));
	uci.sections('wrthotspot', 'server').forEach(function(sv) { o.value(sv['.name']); });
	o.default = 'all';
	return o;
}

return view.extend({
	load: function() {
		return uci.load('wrthotspot');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('wrthotspot', _('Walled garden'),
			_('Destinations reachable without logging in, for IPv4 and IPv6. A host covers the domain and its subdomains (subdomains need dnsmasq-full). "Deny" entries carve exceptions out of broader allows.'));

		s = m.section(form.GridSection, 'walled_garden');
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add entry');

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.editable = true;

		o = s.option(form.ListValue, 'action', _('Action'));
		o.value('allow', _('allow'));
		o.value('deny', _('deny'));
		o.default = 'allow';

		o = s.option(form.Value, 'dst_host', _('Host'));
		o.placeholder = 'example.com';
		o.validate = function(section_id, value) {
			return (!value || /^(\*\.)?([A-Za-z0-9_]([A-Za-z0-9_-]*[A-Za-z0-9_])?\.)*[A-Za-z0-9_]([A-Za-z0-9_-]*[A-Za-z0-9_])?\.?$/.test(value))
				? true : _('A domain name, optionally *.domain');
		};

		o = s.option(form.DynamicList, 'dst_address', _('Addresses'));
		o.datatype = 'or(ip4addr, ip6addr, cidr4, cidr6)';
		o.placeholder = '203.0.113.0/24';

		o = s.option(form.ListValue, 'protocol', _('Protocol'));
		o.value('', _('any'));
		o.value('tcp', 'TCP');
		o.value('udp', 'UDP');

		o = s.option(form.Value, 'dst_port', _('Port'));
		o.datatype = 'portrange';
		o.placeholder = _('any');

		serverOption(s);

		o = s.option(form.Value, 'comment', _('Comment'));

		return m.render();
	}
});
