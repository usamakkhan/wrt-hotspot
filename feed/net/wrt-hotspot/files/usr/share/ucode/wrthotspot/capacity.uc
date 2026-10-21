// Capacity tiers: how many concurrent sessions and local user accounts a
// router can carry while keeping a safety buffer of free memory (and flash
// for the user database). Costs were measured on OpenWrt 25.12 (see
// docs/qualification.md, tests/integration/capacity-probe.uc).
//
// Memory that is shared by all clients and bounded by the kernel or by our
// own settings (connection tracking, portal workers) is set aside once, in
// the reserve, instead of being charged to every session: that charge made
// 64 MB routers end up with no budget at all.
'use strict';

// KiB per item, measured with 1000 of each.
export const COST = {
	session_shaped: 40,	// daemon + nft elements/counters + 2 HTB classes, filters, fq_codel
	session_plain: 20,	// daemon + nft elements/counters (nft policing or no limit)
	host: 5,		// neighbor entry + daemon host record
	user: 5,		// daemon user record + history share
	user_flash: 0.45,	// users.json bytes per account
	conntrack: 0.32,	// one nf_conntrack entry (slab object)
	portal_worker: 400,	// one forked uhttpd portal request
};

// mode ->
//   base:     free memory always kept (fraction of RAM, at least floor KiB)
//   shared:   share of the conntrack table and portal workers set aside
//   traffic:  per-session allowance for the client's own traffic (DNS,
//             sockets, queues), KiB
//   flows:    conntrack entries each session should be able to have
export const MODES = {
	safe:     { base: 0.08, floor: 4096, shared: 1.0,  traffic: 16, flows: 48 },
	balanced: { base: 0.05, floor: 3072, shared: 0.5,  traffic: 8,  flows: 24 },
	max:      { base: 0.03, floor: 2048, shared: 0.25, traffic: 4,  flows: 12 },
};

// Whatever the free memory says, these are always allowed: a hotspot for
// one or two guests is useless, and the reserve above is a buffer, not a
// hard boundary. The daemon warns when it falls back to them.
export const MIN_SESSIONS = 10;
export const MIN_USERS = 100;

const TIERS = [
	[ 65536, 'tiny', '64 MB' ],
	[ 131072, 'small', '128 MB' ],
	[ 262144, 'medium', '256 MB' ],
	[ 524288, 'large', '512 MB' ],
	[ 1048576, 'xlarge', '1 GB' ],
];

// RAM class by MemTotal (the kernel reports a bit less than the chip size).
export function tier(mem_total_kb) {
	for (let t in TIERS)
		if (mem_total_kb <= t[0])
			return { name: t[1], label: t[2] };

	return { name: 'xxlarge', label: 'more than 1 GB' };
};

// Default number of concurrent portal requests (uhttpd -n) when
// portal_max_requests is not set. Keep in sync with /etc/init.d/wrthotspot.
export function portal_workers(mem_total_kb) {
	return (mem_total_kb <= 70000) ? 8 : (mem_total_kb <= 140000) ? 16 : 32;
};

export function session_cost(shaped, mode) {
	return (shaped ? COST.session_shaped : COST.session_plain) + COST.host + (MODES[mode] ?? MODES.safe).traffic;
};

// o: { mem_total_kb, mem_avail_kb, flash_free_kb, shaped, mode,
//      conntrack_max, portal_workers,
//      sessions, users, max_sessions, max_users }  (max_*: manual values, 0 = auto)
// mem_avail_kb / flash_free_kb are measured now, so what the hotspot already
// uses is added back: the limits do not shrink as the hotspot fills up.
export function compute(o) {
	let mode = MODES[o.mode] ? o.mode : 'safe';
	let m = MODES[mode];
	let per_session = session_cost(o.shaped, mode);
	let ct_max = o.conntrack_max ?? 0;
	let workers = o.portal_workers || portal_workers(o.mem_total_kb);

	let reserve = max(m.floor, int(o.mem_total_kb * m.base)) +
		int((ct_max * COST.conntrack + workers * COST.portal_worker) * m.shared);
	let in_use = (o.sessions ?? 0) * per_session + (o.users ?? 0) * COST.user;
	let budget = max(0, (o.mem_avail_kb ?? 0) + in_use - reserve);

	// Sessions get most of the budget; accounts are cheap in RAM but live
	// in flash, and every session usually belongs to an account.
	let sessions = int(budget * 0.85 / per_session);
	let by_memory = sessions;

	// More sessions than the conntrack table can serve only makes every
	// client's connections fail: the kernel drops new flows when it is full.
	let by_conntrack = (ct_max > 0) ? int(ct_max / m.flows) : null;

	if (by_conntrack != null)
		sessions = min(sessions, by_conntrack);

	let low_memory = sessions < MIN_SESSIONS;
	sessions = max(MIN_SESSIONS, sessions);

	let users = max(int(budget * 0.15 / COST.user), sessions, MIN_USERS);
	let low_flash = false;

	if (o.flash_free_kb != null) {
		// Half of the free flash (keeping 1 MB) for the user database.
		let flash = max(0, o.flash_free_kb + (o.users ?? 0) * COST.user_flash - 1024) / 2;
		let by_flash = int(flash / COST.user_flash);

		if (by_flash < users) {
			users = by_flash;
			low_flash = users < MIN_USERS;
		}
	}

	// 0 would mean "unlimited" to the callers.
	users = max(1, users);

	return {
		tier: tier(o.mem_total_kb),
		mode,
		session_cost_kb: per_session,
		reserve_kb: reserve,
		budget_kb: budget,
		conntrack_max: ct_max,
		portal_workers: workers,
		limited_by: (by_conntrack != null && by_conntrack < by_memory && !low_memory) ? 'conntrack' : 'memory',
		max_sessions: (o.max_sessions > 0) ? o.max_sessions : sessions,
		max_users: (o.max_users > 0) ? o.max_users : users,
		auto_sessions: sessions,
		auto_users: users,
		low_memory,
		low_flash,
	};
};
