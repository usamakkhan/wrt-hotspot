// Scheduled limitations (MikroTik User Manager "limitation" + "profile
// limitation"): a time window (weekdays, from/till, overnight allowed), a
// rate limit for that window, and quotas counted per period (hourly, daily,
// weekly, monthly or never reset).
//
// A user profile with limitations only allows access while at least one of
// them is in its window. All active limitations apply at once: the first
// one with a rate limit sets the rate, every quota must hold.
//
// Times are local (hotspotd runs with the system TZ).
'use strict';

const DAYS = { mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6, sun: 7 };

// "08:00", "8:30:15" -> seconds after midnight
export function parse_clock(v) {
	let m = match(`${v ?? ''}`, /^([0-9]{1,2}):([0-9]{2})(:([0-9]{2}))?$/);

	if (!m || int(m[1]) > 24 || int(m[2]) > 59)
		return null;

	return min(86400, int(m[1]) * 3600 + int(m[2]) * 60 + int(m[4] ?? 0));
};

// "mon tue", "mon-fri", "sat,sun" -> { 1: true, ... } (empty = every day)
export function parse_days(v) {
	let out = {};

	// LuCI stores the days as a UCI list.
	if (type(v) == 'array')
		v = join(' ', v);

	for (let tok in split(lc(`${v ?? ''}`), /[ ,]+/)) {
		if (tok == '')
			continue;

		let r = match(tok, /^([a-z]{3})-([a-z]{3})$/);

		if (r && DAYS[r[1]] && DAYS[r[2]]) {
			for (let d = DAYS[r[1]]; ; d = (d % 7) + 1) {
				out[d] = true;
				if (d == DAYS[r[2]])
					break;
			}
		}
		else if (DAYS[tok]) {
			out[DAYS[tok]] = true;
		}
		else {
			return null;
		}
	}

	if (!length(keys(out)))
		for (let d = 1; d <= 7; d++)
			out[d] = true;

	return out;
};

function day_ok(lim, wday) {
	return !!lim.days[wday];
}

function prev_day(wday) {
	return (wday == 1) ? 7 : wday - 1;
}

// tm: localtime() object. Is the limitation's window open now?
export function window_active(lim, tm) {
	let t = tm.hour * 3600 + tm.min * 60 + tm.sec;
	let from = lim.from ?? 0, till = lim.till ?? 86400;

	if (from < till)
		return day_ok(lim, tm.wday) && t >= from && t < till;

	// Overnight window: the part after midnight belongs to the previous day.
	return (day_ok(lim, tm.wday) && t >= from) || (day_ok(lim, prev_day(tm.wday)) && t < till);
};

// Seconds until the currently open window closes (null if it never does,
// i.e. all day on every day).
export function window_left(lim, tm) {
	let t = tm.hour * 3600 + tm.min * 60 + tm.sec;
	let from = lim.from ?? 0, till = lim.till ?? 86400;

	if (from == 0 && till == 86400) {
		// Whole days: runs until the first day that isn't included.
		let left = 86400 - t, wd = tm.wday;

		for (let i = 0; i < 7; i++) {
			wd = (wd % 7) + 1;

			if (!day_ok(lim, wd))
				return left;

			left += 86400;
		}

		return null;
	}

	if (from < till)
		return till - t;

	return (t >= from) ? (86400 - t) + till : till - t;
};

// Start (epoch) of the quota period that contains `now`.
export function period_start(reset, now, reset_at) {
	let tm = localtime(now);
	let at = reset_at ?? 0;
	let base = { ...tm, hour: int(at / 3600), min: int((at % 3600) / 60), sec: at % 60 };

	switch (reset) {
	case 'hourly':
		return timelocal({ ...tm, min: 0, sec: 0 });

	case 'daily': {
		let t = timelocal(base);
		return (t > now) ? timelocal({ ...base, mday: base.mday - 1 }) : t;
	}

	case 'weekly': {
		let t = timelocal({ ...base, mday: base.mday - (tm.wday - 1) });
		return (t > now) ? timelocal({ ...base, mday: base.mday - (tm.wday - 1) - 7 }) : t;
	}

	case 'monthly': {
		let t = timelocal({ ...base, mday: 1 });
		return (t > now) ? timelocal({ ...base, mon: base.mon - 1, mday: 1 }) : t;
	}

	default:
		return 0;		// never resets
	}
};

// UCI section -> limitation, or [ null, error ]
export function parse(s, parse_duration, parse_size) {
	let days = parse_days(s.weekdays);
	let from = (s.from_time != null && s.from_time !== '') ? parse_clock(s.from_time) : null;
	let till = (s.till_time != null && s.till_time !== '') ? parse_clock(s.till_time) : null;

	if (days == null)
		return [ null, `invalid weekdays "${s.weekdays}"` ];

	if ((s.from_time && from == null) || (s.till_time && till == null))
		return [ null, 'invalid from_time/till_time (use HH:MM)' ];

	let reset = s.reset ?? 'never';

	if (!(reset in [ 'never', 'hourly', 'daily', 'weekly', 'monthly' ]))
		return [ null, `invalid reset "${reset}"` ];

	// A typo must not silently mean "unlimited".
	for (let k in [ 'download_limit', 'upload_limit', 'transfer_limit' ])
		if (s[k] != null && s[k] !== '' && parse_size(s[k]) == null)
			return [ null, `invalid ${k} "${s[k]}" (use bytes or e.g. 500M, 2G)` ];

	if (s.uptime_limit != null && s.uptime_limit !== '' && parse_duration(s.uptime_limit) == null)
		return [ null, `invalid uptime_limit "${s.uptime_limit}" (use e.g. 30m, 2h)` ];

	let lim = {
		name: s.name ?? s['.name'],
		days, from, till,
		rate_limit: s.rate_limit ?? '',
		download_limit: parse_size(s.download_limit) ?? 0,
		upload_limit: parse_size(s.upload_limit) ?? 0,
		transfer_limit: parse_size(s.transfer_limit) ?? 0,
		uptime_limit: parse_duration(s.uptime_limit) ?? 0,
		reset,
		reset_at: (s.reset_time != null) ? (parse_clock(s.reset_time) ?? 0) : 0,
	};

	lim.has_quota = !!(lim.download_limit || lim.upload_limit || lim.transfer_limit || lim.uptime_limit);
	return [ lim, null ];
};
