// Capacity tiers: how many concurrent sessions and local user accounts a
// router can carry while keeping a safety buffer of free memory (and flash
// for the user database). Costs were measured on OpenWrt 25.12 (see
// docs/qualification.md, tests/integration/capacity-probe.uc).
'use strict';

// KiB per item, measured with 1000 of each.
export const COST = {
	session_shaped: 40,	// daemon + nft elements/counters + 2 HTB classes, filters, fq_codel
	session_plain: 20,	// daemon + nft elements/counters (nft policing or no limit)
	host: 5,		// neighbor entry + daemon host record
	user: 5,		// daemon user record + history share
	user_flash: 0.45,	// users.json bytes per account
};

// mode -> reserve (fraction of RAM, floor in KiB) and per-session allowance
// for the client's traffic (conntrack entries, socket and queue memory).
export const MODES = {
	safe:     { reserve: 0.30, floor: 16384, traffic: 96 },
	balanced: { reserve: 0.20, floor: 12288, traffic: 48 },
	max:      { reserve: 0.12, floor: 8192,  traffic: 16 },
};

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

export function session_cost(shaped, mode) {
	return (shaped ? COST.session_shaped : COST.session_plain) + COST.host + (MODES[mode] ?? MODES.safe).traffic;
};

// o: { mem_total_kb, mem_avail_kb, flash_free_kb, shaped, mode,
//      sessions, users, max_sessions, max_users }  (max_*: manual values, 0 = auto)
// mem_avail_kb / flash_free_kb are measured now, so what the hotspot already
// uses is added back: the limits do not shrink as the hotspot fills up.
export function compute(o) {
	let mode = MODES[o.mode] ? o.mode : 'safe';
	let m = MODES[mode];
	let per_session = session_cost(o.shaped, mode);
	let in_use = (o.sessions ?? 0) * per_session + (o.users ?? 0) * COST.user;
	let reserve = max(m.floor, int(o.mem_total_kb * m.reserve));
	let budget = max(0, (o.mem_avail_kb ?? 0) + in_use - reserve);

	// Sessions get most of the budget; accounts are cheap in RAM but live
	// in flash, and every session usually belongs to an account.
	let sessions = int(budget * 0.85 / per_session);
	let users = max(int(budget * 0.15 / COST.user), sessions);

	if (o.flash_free_kb != null) {
		// Half of the free flash (keeping 1 MB) for the user database.
		let flash = max(0, o.flash_free_kb + (o.users ?? 0) * COST.user_flash - 1024) / 2;
		users = min(users, int(flash / COST.user_flash));
	}

	return {
		tier: tier(o.mem_total_kb),
		mode,
		session_cost_kb: per_session,
		reserve_kb: reserve,
		budget_kb: budget,
		max_sessions: (o.max_sessions > 0) ? o.max_sessions : sessions,
		max_users: (o.max_users > 0) ? o.max_users : users,
		auto_sessions: sessions,
		auto_users: users,
	};
};
