// MikroTik hotspot page templates: $(var), $(if var), $(if var == x),
// $(if var != x), $(elif ...), $(else), $(endif). Existing MikroTik login
// pages render unmodified.
//
// Only names present in `vars` are substituted; anything else (jQuery's
// $(document), or variables we don't provide) is kept verbatim.
//
// Values are HTML-escaped (MikroTik does not escape, which makes
// $(link-orig) & co. an XSS vector). $(var-raw) opts out for trusted vars.
'use strict';

function escape_html(s) {
	return replace(`${s}`, /[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
}

export { escape_html };

// -> [ node ], node = string | { v: name } | { cond: [ [ test, nodes ] ... ], otherwise: nodes }
export function parse(src) {
	let root = [];
	let stack = [ { nodes: root } ];
	let pos = 0;

	function top() { return stack[length(stack) - 1]; }

	function test(expr) {
		let m = match(expr, /^([A-Za-z0-9_-]+)\s*(==|!=)\s*(.*)$/);

		if (m)
			return { name: m[1], op: m[2], value: trim(m[3]) };

		return { name: trim(expr), op: null };
	}

	while (pos < length(src)) {
		let i = index(substr(src, pos), '$(');

		if (i < 0) {
			push(top().nodes, substr(src, pos));
			break;
		}

		if (i > 0)
			push(top().nodes, substr(src, pos, i));

		let start = pos + i + 2;
		let end = index(substr(src, start), ')');

		if (end < 0) {
			push(top().nodes, substr(src, pos + i));
			break;
		}

		let tag = trim(substr(src, start, end));
		pos = start + end + 1;

		let m;

		if ((m = match(tag, /^if\s+(.+)$/))) {
			let node = { cond: [ [ test(m[1]), [] ] ], otherwise: null };
			push(top().nodes, node);
			push(stack, { node, nodes: node.cond[0][1] });
		}
		else if ((m = match(tag, /^elif\s+(.+)$/)) && top().node) {
			let br = [ test(m[1]), [] ];
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
		else if (match(tag, /^[A-Za-z0-9_-]+$/)) {
			push(top().nodes, { v: tag });
		}
		else {
			// Not a template tag (e.g. jQuery's $(document)); keep it verbatim.
			push(top().nodes, `$(${tag})`);
		}
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

export function render_nodes(nodes, vars) {
	let out = '';

	for (let n in nodes) {
		if (type(n) == 'string') {
			out += n;
		}
		else if (n.v != null) {
			let raw = match(n.v, /^(.+)-raw$/);
			let name = raw ? raw[1] : n.v;

			if (!exists(vars, name)) {
				out += `$(${n.v})`;
				continue;
			}

			let v = lookup(vars, name);

			if (v != null)
				out += raw ? `${v}` : escape_html(v);
		}
		else if (n.cond) {
			let done = false;

			for (let br in n.cond) {
				if (eval_test(br[0], vars)) {
					out += render_nodes(br[1], vars);
					done = true;
					break;
				}
			}

			if (!done && n.otherwise)
				out += render_nodes(n.otherwise, vars);
		}
	}

	return out;
};

export function render(src, vars) {
	return render_nodes(parse(src), vars);
};
