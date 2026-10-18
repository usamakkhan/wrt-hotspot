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

		m = new form.Map('wrthotspot', _('Scheduled limitations'),
			_('Time windows with their own rate limit and quotas (like MikroTik User Manager limitations). Attach them to user profiles. While a profile has limitations, its users may only be online inside one of their windows; quotas are counted per reset period.'));

		s = m.section(form.GridSection, 'limitation');
		s.addremove = true;
		s.anonymous = false;
		s.nodescriptions = true;
		s.addbtntitle = _('Add limitation');

		s.tab('window', _('Time window'));
		s.tab('limits', _('Limits'));

		o = s.taboption('window', form.MultiValue, 'weekdays', _('Days'));
		[ [ 'mon', _('Monday') ], [ 'tue', _('Tuesday') ], [ 'wed', _('Wednesday') ], [ 'thu', _('Thursday') ],
		  [ 'fri', _('Friday') ], [ 'sat', _('Saturday') ], [ 'sun', _('Sunday') ] ].forEach(function(d) { o.value(d[0], d[1]); });
		o.placeholder = _('every day');
		o.optional = true;

		o = s.taboption('window', form.Value, 'from_time', _('From'));
		o.placeholder = '00:00';
		o.validate = hs.validateClock;

		o = s.taboption('window', form.Value, 'till_time', _('Till'), _('Earlier than "From" means overnight.'));
		o.placeholder = '24:00';
		o.validate = hs.validateClock;

		o = s.taboption('limits', form.Value, 'rate_limit', _('Rate limit'), hs.rateLimitHelp);
		o.placeholder = _('from profile');
		o.validate = hs.validateRateLimit;

		o = s.taboption('limits', form.Value, 'download_limit', _('Download quota'));
		o.validate = hs.validateSize;
		o.modalonly = true;

		o = s.taboption('limits', form.Value, 'upload_limit', _('Upload quota'));
		o.validate = hs.validateSize;
		o.modalonly = true;

		o = s.taboption('limits', form.Value, 'transfer_limit', _('Transfer quota'));
		o.validate = hs.validateSize;

		o = s.taboption('limits', form.Value, 'uptime_limit', _('Uptime quota'));
		o.validate = hs.validateDuration;

		o = s.taboption('limits', form.ListValue, 'reset', _('Quota period'));
		o.value('never', _('never reset'));
		o.value('hourly', _('hourly'));
		o.value('daily', _('daily'));
		o.value('weekly', _('weekly (Monday)'));
		o.value('monthly', _('monthly'));
		o.default = 'never';

		o = s.taboption('limits', form.Value, 'reset_time', _('Reset at'));
		o.placeholder = '00:00';
		o.validate = hs.validateClock;
		o.depends({ reset: 'never', '!reverse': true });
		o.modalonly = true;

		return m.render();
	}
});
