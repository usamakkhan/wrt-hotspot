// MikroTik hotspot page templates: $(var), $(if var), $(if var == x),
// $(if var != x), $(elif ...), $(else), $(endif). Existing MikroTik login
// pages render unmodified.
//
// Only names present in `vars` are substituted; anything else (jQuery's
// $(document), or variables we don't provide) is kept verbatim.
//
// Values are HTML-escaped (MikroTik does not escape, which makes
// $(link-orig) & co. an XSS vector). $(var-raw) opts out for trusted vars.
//
// No regular expressions on purpose: a regex match costs ~0.5 ms on a MIPS
// router, and a page has dozens of tags. String functions run in C.
'use strict';

const NAME_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';
const SPACE = ' \t\n\r\f\v';

function escape_html(s) {
	s = `${s}`;

	if (index(s, '&') < 0 && index(s, '<') < 0 && index(s, '>') < 0 && index(s, '"') < 0 && index(s, "'") < 0)
		return s;

	return replace(replace(replace(replace(replace(s, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), "'", '&#39;');
}

export { escape_html };

function is_name(s) {
	return s != '' && ltrim(s, NAME_CHARS) == '';
}

// "if x", "elif x": the expression after the keyword and whitespace, or null.
function after_keyword(tag, kw) {
	let n = length(kw);

	if (substr(tag, 0, n) != kw || index(SPACE, substr(tag, n, 1)) < 0 || substr(tag, n, 1) == '')
		return null;

	let expr = ltrim(substr(tag, n), SPACE);
	return (expr != '' && index(expr, '\n') < 0) ? expr : null;
}

// "name", "name == value", "name != 'value'" (MikroTik quotes the value).
function test(expr) {
	let rest = ltrim(expr, NAME_CHARS);
	let name = substr(expr, 0, length(expr) - length(rest));
	let op = substr(ltrim(rest, SPACE), 0, 2);

	if (name != '' && (op == '==' || op == '!=')) {
		let v = trim(substr(ltrim(rest, SPACE), 2));
		let q = substr(v, 0, 1);

		if (length(v) >= 2 && (q == '"' || q == "'") && substr(v, -1) == q)
			v = substr(v, 1, length(v) - 2);

		return { name, op, value: v };
	}

	return { name: trim(expr), op: null };
}

// -> [ node ], node = string | { v, name, raw } | { cond: [ [ test, nodes ] ... ], otherwise: nodes }
export function parse(src) {
	let root = [];
	let stack = [ { nodes: root } ];

	function top() { return stack[length(stack) - 1]; }

	// One split instead of slicing the rest of the page at every tag.
	let parts = split(src, '$(');

	if (parts[0] != '')
		push(top().nodes, parts[0]);

	for (let k = 1; k < length(parts); k++) {
		// A tag ends at the first ')', which may lie beyond further '$('.
		let body = parts[k];
		let end = index(body, ')');

		while (end < 0 && k + 1 < length(parts)) {
			body += '$(' + parts[++k];
			end = index(body, ')');
		}

		if (end < 0) {
			push(top().nodes, '$(' + body);
			break;
		}

		let tag = trim(substr(body, 0, end));
		let rest = substr(body, end + 1);
		let expr;

		if ((expr = after_keyword(tag, 'if')) != null) {
			let node = { cond: [ [ test(expr), [] ] ], otherwise: null };
			push(top().nodes, node);
			push(stack, { node, nodes: node.cond[0][1] });
		}
		else if ((expr = after_keyword(tag, 'elif')) != null && top().node) {
			let br = [ test(expr), [] ];
			push(top().node.cond, br);
			top().nodes = br[1];
		}
		else if (tag == 'else' && top().node) {
			top().node.otherwise = [];
			top().nodes = top().node.otherwise;
		}
		else if (tag == 'endif' && top().node) {
			pop(stack);
		}
		else if (is_name(tag)) {
			// $(name-raw): the value of `name`, not escaped.
			let raw = length(tag) > 4 && substr(tag, -4) == '-raw';
			push(top().nodes, { v: tag, name: raw ? substr(tag, 0, length(tag) - 4) : tag, raw });
		}
		else {
			// Not a template tag (e.g. jQuery's $(document)); keep it verbatim.
			push(top().nodes, `$(${tag})`);
		}

		if (rest != '')
			push(top().nodes, rest);
	}

	return root;
};

function truthy(v) {
	return v != null && v !== '' && v !== false && v !== 'no' && v !== 0;
}

function lookup(vars, name) {
	let v = vars[name];
	return (type(v) == 'function') ? v() : v;
}

function eval_test(t, vars) {
	let v = lookup(vars, t.name);

	if (t.op == '==')
		return `${v ?? ''}` == t.value;

	if (t.op == '!=')
		return `${v ?? ''}` != t.value;

	return truthy(v);
}

function render_into(out, nodes, vars) {
	for (let n in nodes) {
		if (type(n) == 'string') {
			push(out, n);
		}
		else if (n.v != null) {
			if (!exists(vars, n.name)) {
				push(out, `$(${n.v})`);
				continue;
			}

			let v = lookup(vars, n.name);

			if (v != null)
				push(out, n.raw ? `${v}` : escape_html(v));
		}
		else if (n.cond) {
			let done = false;

			for (let br in n.cond) {
				if (eval_test(br[0], vars)) {
					render_into(out, br[1], vars);
					done = true;
					break;
				}
			}

			if (!done && n.otherwise)
				render_into(out, n.otherwise, vars);
		}
	}

	return out;
}

export function render_nodes(nodes, vars) {
	return join('', render_into([], nodes, vars));
};

export function render(src, vars) {
	return render_nodes(parse(src), vars);
};
