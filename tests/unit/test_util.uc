'use strict';
import { suite, eq, ok, done } from 'assert';
import * as u from 'wrthotspot.util';

suite('util');

eq(u.parse_duration('1d2h3m4s'), 93784, 'compound duration');
eq(u.parse_duration('30m'), 1800, 'minutes');
eq(u.parse_duration('00:05:00'), 300, 'hh:mm:ss');
eq(u.parse_duration('none'), 0, 'none');
eq(u.parse_duration(''), 0, 'empty');
eq(u.parse_duration('45'), 45, 'plain seconds');
eq(u.parse_duration('1w'), 604800, 'week');
eq(u.parse_duration('5x'), null, 'garbage');
eq(u.fmt_duration(93784), '1d2h3m4s', 'format');
eq(u.fmt_duration(0), '0s', 'format zero');

eq(u.parse_size('10M'), 10485760, 'MiB');
eq(u.parse_size('1.5G'), 1610612736, 'fractional GiB');
eq(u.parse_size('500'), 500, 'bytes');
eq(u.parse_size('0'), 0, 'zero');
eq(u.parse_size('abc'), null, 'garbage');

eq(u.normalize_mac('AA-BB-CC-DD-EE-FF'), 'aa:bb:cc:dd:ee:ff', 'dash mac');
eq(u.normalize_mac('aabbccddeeff'), 'aa:bb:cc:dd:ee:ff', 'bare mac');
eq(u.normalize_mac('zz:bb:cc:dd:ee:ff'), null, 'bad mac');
eq(u.normalize_mac(' 02:00:00:00:99:1A '), '02:00:00:00:99:1a', 'spaces trimmed, lower case');
eq(u.normalize_mac('a:bb:cc:dd:ee:fff'), null, 'groups of the wrong size');
eq(u.normalize_mac('aa:bb:cc:dd:ee'), null, 'too short');
eq(u.normalize_mac('aabbccddeeff00'), null, '14 hex digits');
eq(u.normalize_mac(null), null, 'no mac');

eq(u.normalize_ip('::ffff:192.168.1.5'), '192.168.1.5', 'v4-mapped');
eq(u.normalize_ip('::FFFF:10.0.0.1'), '10.0.0.1', 'v4-mapped, upper case');
eq(u.normalize_ip('::ffff:1.2.3'), '::ffff:1.2.3', 'not a full IPv4 address: kept');
eq(u.normalize_ip('::ffff:1..2.3'), '::ffff:1..2.3', 'empty octet: kept');
eq(u.normalize_ip('::ffff:a00:1'), '::ffff:a00:1', 'hex form: kept');
eq(u.normalize_ip('fe80::1%br-lan'), 'fe80::1', 'zone id stripped');
eq(u.normalize_ip('2001:DB8::1'), '2001:db8::1', 'v6 lowercased');
eq(u.ip_family('10.0.0.1'), 4, 'family 4');
eq(u.ip_family('2001:db8::1'), 6, 'family 6');

eq(length(u.random_hex(8)), 16, 'random hex length');
eq(u.shell_quote("a'b"), sprintf("'a'%c''b'", 92), 'shell quote');
ok(u.to_bool('yes') && !u.to_bool('0'), 'to_bool');
eq(u.as_list('a b,c'), [ 'a', 'b', 'c' ], 'as_list');

done();
