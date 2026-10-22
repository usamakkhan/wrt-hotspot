'use strict';
import { suite, eq, done } from 'assert';
import { matches, bypassed } from 'wrthotspot.binding';
import { parse_prefix } from 'wrthotspot.config';

suite('binding display');

let host = { mac: '02:00:00:00:00:01', server: 'guest', ipv4: [ '192.168.55.208' ], ipv6: [ 'fd55::208' ] };
let ip = { type: 'bypassed', server: 'all', address: parse_prefix('192.168.55.208') };

eq(bypassed(host, [ ip ]), true, 'IP-only bypass appears for a live host');
eq(bypassed({ ...host, ipv4: [ '192.168.55.209' ] }, [ ip ]), false, 'different address is not bypassed');
eq(bypassed(host, [ { ...ip, address: parse_prefix('192.168.55.0/24') } ]), true, 'prefix covers host');
eq(bypassed(host, [ { ...ip, address: parse_prefix('192.168.56.0/24') } ]), false, 'unrelated prefix');
eq(bypassed(host, [ { ...ip, address: parse_prefix('fd55::/64') } ]), true, 'IPv6 prefix covers host');
eq(bypassed(host, [ { ...ip, mac: host.mac } ]), true, 'MAC and address pair');
eq(bypassed(host, [ { ...ip, mac: '02:00:00:00:00:02' } ]), false, 'wrong MAC does not match');
eq(bypassed(host, [ { ...ip, server: 'other' } ]), false, 'wrong server does not match');
eq(bypassed(host, [ { type: 'bypassed', mac: host.mac } ]), true, 'MAC-only binding');
eq(bypassed(host, [ ip, { ...ip, type: 'blocked' } ]), false, 'blocked binding takes priority');
eq(matches(ip, host, '192.168.55.208'), true, 'exact IP match');

done();
