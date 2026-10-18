'use strict';
import { suite, eq, ok, done } from 'assert';
import * as nft from 'wrthotspot.nft';

suite('nft');

eq(nft.slot_mark(1), 65536, 'slot mark shift');
eq(nft.slot_mark(65535), 4294901760, 'max slot');

let r = nft.ruleset({ ifaces: [ 'br-hs' ], port: 8002, sessions: [ { slot: 3, mac: 'aa:bb:cc:dd:ee:ff' } ] });

ok(index(r, 'delete table inet wrthotspot') > 0, 'atomic replace');
ok(index(r, 'elements = { "br-hs" }') > 0, 'interfaces');
ok(index(r, 'aa:bb:cc:dd:ee:ff : 196608') > 0, 'mac2id element');
ok(index(r, 'counter cu_3 { }') > 0, 'upload counter');
ok(index(r, '196608 : "cd_3"') > 0, 'download counter map');
ok(index(r, 'redirect to :8002') > 0, 'portal port');
ok(index(r, 'ip6 daddr @wgd6 return') > 0, 'ipv6 walled garden');
ok(index(r, 'elements = {  }') < 0, 'no empty element lists');

let add = nft.session_add_cmds(3, 'aa:bb:cc:dd:ee:ff');
eq(length(add), 7, 'add cmds');
ok(index(join('\n', nft.session_del_cmds(3, 'aa:bb:cc:dd:ee:ff')), 'destroy counter inet wrthotspot cd_3') >= 0, 'del uses destroy');

done();
