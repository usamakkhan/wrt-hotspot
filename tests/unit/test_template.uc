'use strict';
import { suite, eq, done } from 'assert';
import { render } from 'wrthotspot.template';

suite('template');

let v = { 'username': 'bob', 'logged-in': 'yes', 'trial': 'no', 'error': '', 'link-orig': 'http://x/?a=1&b=<2>' };

eq(render('Hi $(username)!', v), 'Hi bob!', 'variable');
eq(render('$(missing)', v), '$(missing)', 'unknown name kept verbatim');
eq(render('[$(error)]', v), '[]', 'known but empty');
eq(render('$(link-orig)', v), 'http://x/?a=1&amp;b=&lt;2&gt;', 'escaped');
eq(render('$(link-orig-raw)', v), 'http://x/?a=1&b=<2>', 'raw');
eq(render('$(if logged-in == yes)IN$(else)OUT$(endif)', v), 'IN', 'if ==');
eq(render('$(if trial == yes)T$(elif logged-in)L$(else)N$(endif)', v), 'L', 'elif');
eq(render('$(if error)E$(endif)ok', v), 'ok', 'empty is false');
eq(render('$(if trial != yes)no-trial$(endif)', v), 'no-trial', '!=');
eq(render('$(if logged-in)$(if trial == yes)a$(else)b$(endif)$(endif)', v), 'b', 'nested');
eq(render('$(document).ready()', v), '$(document).ready()', 'jQuery untouched');
eq(render('price $(', v), 'price $(', 'unterminated');
// MikroTik's stock pages quote the compared value.
eq(render("$(if trial == 'no')N$(else)Y$(endif)", v), 'N', 'single-quoted value');
eq(render('$(if error == "")none$(else)err$(endif)', v), 'none', 'double-quoted empty value');
eq(render('$(if username != "bob")x$(else)y$(endif)', v), 'y', 'quoted !=');

done();
