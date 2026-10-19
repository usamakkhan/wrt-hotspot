'use strict';
import { suite, eq, done } from 'assert';
import { parse_prefix, parse_host, parse_proxy, radius_preset } from 'wrthotspot.config';
import { parse_nslookup } from 'wrthotspot.dns';

suite('config');

eq(parse_proxy(null), { local: true, port: 3128 }, 'proxy: default = local 3128');
eq(parse_proxy('0.0.0.0:0'), { local: true, port: 3128 }, 'proxy: MikroTik default');
eq(parse_proxy(':8080'), { local: true, port: 8080 }, 'proxy: local port');
eq(parse_proxy('10.0.0.5:3128'), { local: false, family: 4, address: '10.0.0.5', port: 3128 }, 'proxy: remote v4');
eq(parse_proxy('[2001:DB8::5]:3128'), { local: false, family: 6, address: '2001:db8::5', port: 3128 }, 'proxy: remote v6');
eq(parse_proxy('proxy.lan:3128'), null, 'proxy: host names are not accepted');
eq(parse_proxy('10.0.0.5:99999'), null, 'proxy: bad port');

eq(radius_preset('sas4'), 'mikrotik', 'preset alias sas4');
eq(radius_preset('radiusdesk'), 'coova', 'preset alias radiusdesk');
eq(radius_preset('generic'), 'generic', 'preset generic');
eq(radius_preset('whatever'), 'mikrotik', 'unknown preset = mikrotik');

eq(parse_prefix('10.0.0.5/8'), { family: 4, cidr: '10.0.0.0/8' }, 'host bits cleared');
eq(parse_prefix('192.168.1.7'), { family: 4, cidr: '192.168.1.7' }, 'single v4');
eq(parse_prefix('2001:DB8::1/32'), { family: 6, cidr: '2001:db8::/32' }, 'v6 prefix');
eq(parse_prefix('fd00::1'), { family: 6, cidr: 'fd00::1' }, 'single v6');
eq(parse_prefix('10.0.0.0/33'), null, 'prefix too long');
eq(parse_prefix('nonsense'), null, 'garbage');

eq(parse_host('*.Example.COM'), 'example.com', 'wildcard stripped');
eq(parse_host('login.wifi.'), 'login.wifi', 'trailing dot');
eq(parse_host('bad host'), null, 'space rejected');
eq(parse_host('a;rm -rf'), null, 'shell chars rejected');

let out = 'Server:\t\t127.0.0.1\nAddress:\t127.0.0.1:53\n\nNon-authoritative answer:\nName:\topenwrt.org\nAddress: 64.226.122.113\n\n' +
	'Non-authoritative answer:\nName:\topenwrt.org\nAddress: 2a03:b0c0:3:d0::1a51:c001\n';
eq(parse_nslookup(out), { v4: [ '64.226.122.113' ], v6: [ '2a03:b0c0:3:d0::1a51:c001' ] }, 'nslookup parsed, server line skipped');
eq(parse_nslookup("** server can't find x: NXDOMAIN\n"), { v4: [], v6: [] }, 'nxdomain');

done();
