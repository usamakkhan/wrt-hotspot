'use strict';
import { suite, eq, ok, done } from 'assert';
import * as sh from 'wrthotspot.shaper';
import * as L from 'wrthotspot.limits';

suite('shaper+limits');

eq(sh.parse_rate('512k'), 512000, 'k = 1000');
eq(sh.parse_rate('1.5M'), 1500000, 'fractional M');
eq(sh.parse_rate('2000000'), 2000000, 'plain bits');
eq(sh.parse_rate('1x'), null, 'garbage rate');

let r = sh.parse_rate_limit('512k/2M');
eq(r.rx.rate, 512000, 'rx = upload');
eq(r.tx.rate, 2000000, 'tx = download');
eq(r.tx.burst_rate, 0, 'no burst');
eq(r.tx.priority, 8, 'default priority');

r = sh.parse_rate_limit('1M/2M 4M/8M 768k/1500k 16/8 3 256k/512k');
eq([ r.rx.burst_rate, r.tx.burst_rate ], [ 4000000, 8000000 ], 'burst rates');
eq([ r.rx.burst_threshold, r.tx.burst_threshold ], [ 768000, 1500000 ], 'thresholds');
eq([ r.rx.burst_time, r.tx.burst_time ], [ 16, 8 ], 'burst times');
eq(r.tx.priority, 3, 'priority');
eq([ r.rx.min_rate, r.tx.min_rate ], [ 256000, 512000 ], 'min rates (limit-at)');

r = sh.parse_rate_limit('2M');
eq([ r.rx.rate, r.tx.rate ], [ 2000000, 2000000 ], 'single value both ways');
r = sh.parse_rate_limit('1M/1M 2M/2M');
eq(r.rx.burst_threshold, 1000000, 'threshold defaults to rate');

eq(sh.parse_rate_limit(''), null, 'empty');
eq(sh.parse_rate_limit('1M/1M 2M'), sh.parse_rate_limit('1M/1M 2M/2M'), 'single burst value');
eq(sh.parse_rate_limit('fast'), null, 'garbage');
eq(sh.parse_rate_limit('1M 2M 1M 8 9'), null, 'priority out of range');

let d = sh.parse_rate_limit('1M/1M 4M/4M 768k/768k 8/8').tx;
ok(sh.burst_allowed(d, 0), 'burst at start (average 0)');
ok(!sh.burst_allowed(d, 900000), 'no burst above threshold');
eq(sh.effective_ceil(d, true), 4000000, 'ceil while bursting');
eq(sh.effective_ceil(d, false), 1000000, 'ceil after burst');
ok(!sh.burst_allowed(sh.parse_rate_limit('1M/1M').tx, 0), 'no burst configured');

// 4 Mbit/s for 2 s inside an 8 s window: MikroTik counts the rest as idle -> 1 Mbit/s.
eq(sh.window_avg([ [ 100, 0 ], [ 102, 1000000 ] ], 8, 102), 1000000, 'average over a partly filled window');
eq(sh.window_avg([ [ 100, 0 ], [ 110, 10000000 ], [ 118, 18000000 ] ], 8, 118), 8000000, 'average over the last window only');

eq(sh.nft_limit(8000000), { rate: 1000000, burst: 4500 }, 'nft policer bytes');
eq(sh.nft_limit(0), null, 'unlimited');

// Limitations.
eq(L.parse_clock('08:30'), 30600, 'clock');
eq(L.parse_clock('25:00'), null, 'bad clock');
eq(keys(L.parse_days('mon-fri')), [ '1', '2', '3', '4', '5' ], 'day range');
eq(sort(keys(L.parse_days('fri-mon'))), [ '1', '5', '6', '7' ], 'wrapping range');
eq(length(keys(L.parse_days(''))), 7, 'empty = every day');
eq(L.parse_days('funday'), null, 'bad day');

let tm = (wday, h, m) => ({ wday, hour: h, min: m, sec: 0 });
let office = { days: L.parse_days('mon-fri'), from: L.parse_clock('08:00'), till: L.parse_clock('18:00') };
ok(L.window_active(office, tm(1, 9, 0)), 'office: Monday 9:00');
ok(!L.window_active(office, tm(1, 18, 0)), 'office: Monday 18:00 closed');
ok(!L.window_active(office, tm(6, 9, 0)), 'office: Saturday closed');
eq(L.window_left(office, tm(1, 17, 30)), 1800, 'office: 30 min left');

let night = { days: L.parse_days('fri'), from: L.parse_clock('22:00'), till: L.parse_clock('06:00') };
ok(L.window_active(night, tm(5, 23, 0)), 'overnight: Friday 23:00');
ok(L.window_active(night, tm(6, 5, 0)), 'overnight: Saturday 05:00 belongs to Friday');
ok(!L.window_active(night, tm(6, 23, 0)), 'overnight: Saturday 23:00 closed');
eq(L.window_left(night, tm(5, 23, 0)), 7 * 3600, 'overnight: 7 h left at 23:00');

let weekend = { days: L.parse_days('sat sun') };
eq(L.window_left(weekend, tm(6, 12, 0)), 36 * 3600, 'whole days: until Monday 00:00');
eq(L.window_left({ days: L.parse_days('') }, tm(3, 12, 0)), null, 'always open');

// Periods (TZ of the test system; checks are relative so any zone works).
let now = timelocal({ year: 2026, mon: 10, mday: 18, hour: 14, min: 30, sec: 0 });		// Sunday
eq(L.period_start('daily', now, 0), timelocal({ year: 2026, mon: 10, mday: 18, hour: 0, min: 0, sec: 0 }), 'daily');
eq(L.period_start('daily', now, L.parse_clock('16:00')), timelocal({ year: 2026, mon: 10, mday: 17, hour: 16, min: 0, sec: 0 }), 'daily at 16:00 -> yesterday');
eq(L.period_start('weekly', now, 0), timelocal({ year: 2026, mon: 10, mday: 12, hour: 0, min: 0, sec: 0 }), 'weekly from Monday');
eq(L.period_start('monthly', now, 0), timelocal({ year: 2026, mon: 10, mday: 1, hour: 0, min: 0, sec: 0 }), 'monthly');
eq(L.period_start('hourly', now, 0), timelocal({ year: 2026, mon: 10, mday: 18, hour: 14, min: 0, sec: 0 }), 'hourly');
eq(L.period_start('never', now, 0), 0, 'never');

done();
