'use strict';
import { suite, ok, eq, done } from 'assert';
import { valid_name, valid_path, EXTENSIONS } from 'wrthotspot.pages';

suite('pages');

ok(valid_name('my-pages_2'), 'name');
ok(!valid_name(''), 'empty name');
ok(!valid_name('a/b'), 'slash in name');
ok(!valid_name('..'), 'dots in name');
ok(valid_name(sprintf('%032d', 0)), '32 characters');
ok(!valid_name(sprintf('%033d', 0)), 'name too long');
ok(!valid_name(null), 'no name');

ok(valid_path('login.html'), 'page');
ok(valid_path('css/style.css'), 'subfolder');
ok(valid_path('img/a/b/logo.SVG'), 'upper-case extension, 4 levels');
ok(!valid_path('a/b/c/d/e.png'), '5 levels');
ok(!valid_path('../etc/passwd.txt'), 'parent');
ok(!valid_path('/etc/x.html'), 'absolute');
ok(!valid_path('.hidden.css'), 'hidden file');
ok(!valid_path('css/.x/y.css'), 'hidden folder');
ok(!valid_path('run.sh'), 'script extension');
ok(!valid_path('cgi-bin/x'), 'no extension');
ok(!valid_path('a b.html'), 'space');
ok(!valid_path('a//b.html'), 'empty segment');
ok(!valid_path(sprintf('%0130d.html', 0)), 'too long');
ok(!valid_path(null), 'no path');
eq('sh' in EXTENSIONS, false, 'no shell scripts');

done();
