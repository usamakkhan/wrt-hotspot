'use strict';
import { suite, eq, ok, done } from 'assert';
import * as cap from 'wrthotspot.capacity';

suite('capacity');

eq(cap.tier(59000).name, 'tiny', '64 MB router');
eq(cap.tier(123000).label, '128 MB', '128 MB router (kernel reports less)');
eq(cap.tier(240000).name, 'medium', '256 MB router');
eq(cap.tier(2000000).name, 'xxlarge', 'more than 1 GB');

eq(cap.session_cost(true, 'safe'), 141, 'shaped session, safe: 40 + host 5 + traffic 96');
eq(cap.session_cost(false, 'max'), 41, 'unshaped session, max: 20 + 5 + 16');
eq(cap.session_cost(true, 'nonsense'), 141, 'unknown mode counts as safe');

// 128 MB router, 75 MB available, HTB shaping, safe mode.
let c = cap.compute({ mem_total_kb: 123000, mem_avail_kb: 75000, shaped: true, mode: 'safe' });
eq(c.reserve_kb, 36900, 'reserve: 30% of RAM');
eq(c.budget_kb, 38100, 'budget: available - reserve');
eq(c.max_sessions, 229, 'sessions from 85% of the budget');
eq(c.max_users, 1143, 'accounts from 15% of the budget');
eq(c.tier.label, '128 MB', 'tier');

// Same router with the hotspot in use: limits must not shrink.
let used = cap.compute({ mem_total_kb: 123000, mem_avail_kb: 75000 - 100 * 141 - 500 * 5,
	shaped: true, mode: 'safe', sessions: 100, users: 500 });
eq([ used.max_sessions, used.max_users ], [ 229, 1143 ], 'stable while sessions and users grow');

// Flash bounds the accounts.
eq(cap.compute({ mem_total_kb: 123000, mem_avail_kb: 75000, flash_free_kb: 3000, shaped: true, mode: 'safe' }).max_users,
	1143, 'enough flash: RAM decides');
eq(cap.compute({ mem_total_kb: 123000, mem_avail_kb: 75000, flash_free_kb: 1500, shaped: true, mode: 'safe' }).max_users,
	528, 'little flash: half of (free - 1 MB) / 0.45 KiB');

// 64 MB router without shaping: the 16 MB floor keeps a buffer.
c = cap.compute({ mem_total_kb: 59000, mem_avail_kb: 25000, shaped: false, mode: 'safe' });
eq(c.reserve_kb, 17700, 'tiny router reserve');
eq(c.max_sessions, 51, 'tiny router sessions');
ok(c.max_users >= c.max_sessions, 'at least one account per session');

// Out of memory already: nothing left, not negative.
c = cap.compute({ mem_total_kb: 59000, mem_avail_kb: 8000, shaped: false, mode: 'safe' });
eq([ c.budget_kb, c.max_sessions ], [ 0, 0 ], 'no budget');

// max mode on the 236 MB test VM.
eq(cap.compute({ mem_total_kb: 236776, mem_avail_kb: 140000, shaped: true, mode: 'max' }).max_sessions, 1554, 'max mode');

// Manual limits win.
c = cap.compute({ mem_total_kb: 123000, mem_avail_kb: 75000, shaped: true, mode: 'safe', max_sessions: 500, max_users: 9000 });
eq([ c.max_sessions, c.max_users, c.auto_sessions ], [ 500, 9000, 229 ], 'manual max_sessions / max_users');

done();
