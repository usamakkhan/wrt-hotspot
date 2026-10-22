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

		m = new form.Map('wrthotspot', _('User profiles'),
			_('Limits applied to users (MikroTik /ip hotspot user profile). RADIUS attributes override them; Mikrotik-Group selects a profile.'));

		s = m.section(form.GridSection, 'user_profile');
		s.addremove = true;
		s.anonymous = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add user profile');
		s.sectiontitle = function(section_id) {
			return uci.get('wrthotspot', section_id, 'name') || section_id;
		};

		s.tab('general', _('General'));
		s.tab('cookies', _('Cookies'));
		s.tab('scripts', _('Scripts'));

		o = s.taboption('general', form.Value, 'name', _('Name'));
		o.rmempty = false;
		o.modalonly = true;	// the grid's title column already shows it
		o.validate = function(section_id, value) {
			if (!value || !/^[A-Za-z0-9_.-]+$/.test(value))
				return _('Use letters, digits, ".", "_" and "-"');

			return uci.sections('wrthotspot', 'user_profile').some(function(p) {
				return p['.name'] != section_id && p.name == value;
			}) ? _('Name already used') : true;
		};

		o = s.taboption('general', form.Value, 'rate_limit', _('Rate limit'), hs.rateLimitHelp);
		o.placeholder = _('unlimited');
		o.validate = hs.validateRateLimit;

		o = s.taboption('general', form.Value, 'shared_users', _('Shared users'), _('Simultaneous logins per user; "unlimited" for no limit.'));
		o.placeholder = '1';
		o.validate = function(section_id, value) {
			return (!value || value == 'unlimited' || /^[0-9]+$/.test(value)) ? true : _('A number or "unlimited"');
		};

		o = s.taboption('general', form.Value, 'session_timeout', _('Session timeout'));
		o.placeholder = _('none');
		o.validate = hs.validateDuration;

		o = s.taboption('general', form.Value, 'idle_timeout', _('Idle timeout'));
		o.placeholder = _('none');
		o.validate = hs.validateDuration;

		o = s.taboption('general', form.Value, 'keepalive_timeout', _('Keepalive timeout'), _('Log out devices that left (no neighbor entry, no traffic).'));
		o.placeholder = '2m';
		o.validate = hs.validateDuration;
		o.modalonly = true;

		o = s.taboption('general', form.Value, 'status_autorefresh', _('Status page refresh'));
		o.placeholder = '1m';
		o.validate = hs.validateDuration;
		o.modalonly = true;

		o = s.taboption('general', form.MultiValue, 'limitation', _('Scheduled limitations'),
			_('Users of this profile may only be online inside one of these windows.'));
		uci.sections('wrthotspot', 'limitation').forEach(function(l) { o.value(l['.name']); });
		o.optional = true;

		o = s.taboption('cookies', form.Flag, 'add_mac_cookie', _('Add MAC cookie'), _('Used when the server profile logs in by MAC cookie.'));
		o.default = '1';
		o.modalonly = true;

		o = s.taboption('cookies', form.Value, 'mac_cookie_timeout', _('MAC cookie timeout'));
		o.placeholder = '3d';
		o.validate = hs.validateDuration;
		o.modalonly = true;

		o = s.taboption('scripts', form.TextValue, 'on_login', _('On login'),
			_('Shell commands; environment: HS_USER, HS_MAC, HS_ADDRESS, HS_ADDRESS6, HS_SERVER, HS_SESSION_ID, HS_LOGIN_BY.'));
		o.rows = 3;
		o.modalonly = true;

		o = s.taboption('scripts', form.TextValue, 'on_logout', _('On logout'), _('Also HS_CAUSE, HS_UPTIME, HS_BYTES_IN, HS_BYTES_OUT.'));
		o.rows = 3;
		o.modalonly = true;

		return hs.wrap(m.render());
	}
});
