'use strict';
import { suite, eq, ok, done } from 'assert';
import * as fs from 'fs';
import * as users from 'wrthotspot.users';

suite('users');

let dir = `/tmp/wrthotspot-test-${time()}`;
let db = users.create(dir);
eq(db.load(), 0, 'empty db');

let r = db.set('alice', { password: 'pw', limit_uptime: '1h', limit_bytes_total: '100M', mac: 'AA-BB-CC-DD-EE-FF' });
eq(r[1], null, 'create ok');
eq(r[0].limit_uptime, 3600, 'duration parsed');
eq(r[0].limit_bytes_total, 104857600, 'size parsed');
eq(r[0].mac, 'aa:bb:cc:dd:ee:ff', 'mac normalized');

eq(db.set('bob', { mac: 'nonsense' })[1], 'invalid value for mac', 'bad mac rejected');
eq(db.set('', {})[1], 'invalid user name', 'empty name rejected');

db.add_usage('alice', 60, 1000, 2000);
db.save();

let db2 = users.create(dir);
eq(db2.load(), 1, 'persisted');
eq(db2.get('alice').used, { uptime: 60, bytes_in: 1000, bytes_out: 2000 }, 'usage persisted');
eq(users.public_view(db2.get('alice')).password, null, 'password hidden');

ok(db2.remove('alice'), 'remove');
eq(db2.count(), 0, 'removed');

fs.unlink(`${dir}/users.json`);
fs.rmdir(dir);
done();
