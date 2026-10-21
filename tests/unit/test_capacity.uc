'use strict';
import { suite, eq, ok, done } from 'assert';
import * as cap from 'wrthotspot.capacity';

suite('capacity');

eq(cap.tier(59000).name, 'tiny', '64 MB router');
eq(cap.tier(123000).label, '128 MB', '128 MB router (kernel reports less)');
eq(cap.tier(240000).name, 'medium', '256 MB router');
eq(cap.tier(2000000).name, 'xxlarge', 'more than 1 GB');

eq(cap.session_cost(true, 'safe'), 61, 'shaped session, safe: 40 + host 5 + traffic 16');
eq(cap.session_cost(false, 'max'), 29, 'unshaped session, max: 20 + 5 + 4');
eq(cap.session_cost(true, 'nonsense'), 61, 'unknown mode counts as safe');

eq([ cap.portal_workers(59000), cap.portal_workers(123000), cap.portal_workers(240000) ], [ 8, 16, 32 ],
	'portal workers by RAM (same as the init script)');

// 64 MB router with 14 MB available with the hotspot, LuCI and the panel
// running; conntrack table 7168 entries.
let tiny = { mem_total_kb: 59000, mem_avail_kb: 14000, conntrack_max: 7168, shaped: false };
let c = cap.compute({ ...tiny, mode: 'safe' });
eq(c.reserve_kb, 10213, 'tiny safe reserve: 8% of RAM + conntrack table + 8 portal workers');
eq([ c.max_sessions, c.max_users ], [ 78, 113 ], 'tiny router, safe: dozens of sessions, not 1');
ok(!c.low_memory, 'not the low-memory minimum');
eq(cap.compute({ ...tiny, mode: 'balanced' }).max_sessions, 210, 'tiny router, balanced');
eq(cap.compute({ ...tiny, mode: 'max' }).max_sessions, 310, 'tiny router, max');
eq(cap.compute({ ...tiny, mode: 'safe', portal_workers: 32 }).max_sessions, 10,
	'32 portal workers would eat the budget of a 64 MB router');

// 128 MB router, 75 MB available, HTB shaping: the conntrack table limits.
let small = { mem_total_kb: 123000, mem_avail_kb: 75000, conntrack_max: 15360, shaped: true, mode: 'safe' };
c = cap.compute(small);
eq(c.reserve_kb, 21155, '128 MB safe reserve');
eq(c.budget_kb, 53845, 'budget: available - reserve');
eq(c.max_sessions, 320, 'sessions capped at 48 flows each (15360 / 48)');
eq(c.limited_by, 'conntrack', 'reported as limited by conntrack');
eq(c.max_users, 1615, 'accounts from 15% of the budget');
eq(c.tier.label, '128 MB', 'tier');

// No conntrack (module not loaded): memory decides.
c = cap.compute({ ...small, conntrack_max: 0 });
eq([ c.max_sessions, c.limited_by ], [ 818, 'memory' ], 'without conntrack: memory limits');

// The hotspot in use: limits must not shrink.
let used = cap.compute({ ...small, mem_avail_kb: 75000 - 100 * 61 - 500 * 5, sessions: 100, users: 500 });
eq([ used.max_sessions, used.max_users ], [ 320, 1615 ], 'stable while sessions and users grow');

// Flash bounds the accounts.
eq(cap.compute({ ...small, flash_free_kb: 3000 }).max_users, 1615, 'enough flash: RAM decides');
c = cap.compute({ ...small, flash_free_kb: 1500 });
eq([ c.max_users, c.low_flash ], [ 528, false ], 'little flash: half of (free - 1 MB) / 0.45 KiB');
c = cap.compute({ ...small, flash_free_kb: 1100 });
eq([ c.max_users, c.low_flash ], [ 84, true ], 'below 100 accounts: flagged');
c = cap.compute({ ...small, flash_free_kb: 0 });
eq(c.max_users, 1, 'no flash left: accounts limited to 1, never 0');

// Out of memory already: the minimum, flagged, never 0 ("unlimited").
c = cap.compute({ mem_total_kb: 59000, mem_avail_kb: 8000, conntrack_max: 7168, shaped: false, mode: 'safe' });
eq([ c.budget_kb, c.max_sessions, c.max_users ], [ 0, 10, 100 ], 'no budget: 10 sessions, 100 accounts');
ok(c.low_memory, 'no budget is flagged');
ok(!cap.compute(small).low_memory, 'normal budget not flagged');

// max mode on the 236 MB test VM.
eq(cap.compute({ mem_total_kb: 236776, mem_avail_kb: 140000, conntrack_max: 65536, shaped: true, mode: 'max' }).max_sessions,
	2158, 'max mode');

// Manual limits win.
c = cap.compute({ ...small, max_sessions: 500, max_users: 9000 });
eq([ c.max_sessions, c.max_users, c.auto_sessions ], [ 500, 9000, 320 ], 'manual max_sessions / max_users');

done();
