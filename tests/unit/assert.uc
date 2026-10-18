'use strict';

let failures = 0, passed = 0, name = '';

export function suite(n) { name = n; };

export function eq(got, want, what) {
	let g = sprintf('%J', got), w = sprintf('%J', want);
	if (g === w) { passed++; return true; }
	failures++;
	warn(`FAIL [${name}] ${what}\n   got:  ${g}\n   want: ${w}\n`);
	return false;
};

export function ok(cond, what) { return eq(!!cond, true, what); };

export function done() {
	print(`${name}: ${passed} passed, ${failures} failed\n`);
	exit(failures ? 1 : 0);
};
