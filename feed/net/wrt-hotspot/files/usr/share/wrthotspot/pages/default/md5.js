/* MD5 (RFC 1321) over a byte string, for http-chap logins. */
function hexMD5(s) {
	function add(x, y) { var l = (x & 0xffff) + (y & 0xffff); return (((x >> 16) + (y >> 16) + (l >> 16)) << 16) | (l & 0xffff); }
	function rol(n, c) { return (n << c) | (n >>> (32 - c)); }
	function cmn(q, a, b, x, s, t) { return add(rol(add(add(a, q), add(x, t)), s), b); }
	function ff(a, b, c, d, x, s, t) { return cmn((b & c) | (~b & d), a, b, x, s, t); }
	function gg(a, b, c, d, x, s, t) { return cmn((b & d) | (c & ~d), a, b, x, s, t); }
	function hh(a, b, c, d, x, s, t) { return cmn(b ^ c ^ d, a, b, x, s, t); }
	function ii(a, b, c, d, x, s, t) { return cmn(c ^ (b | ~d), a, b, x, s, t); }

	var n = s.length, i, w = [];
	for (i = 0; i < n; i++) w[i >> 2] |= (s.charCodeAt(i) & 0xff) << ((i % 4) * 8);
	w[n >> 2] |= 0x80 << ((n % 4) * 8);
	var len = (((n + 8) >> 6) + 1) * 16;
	for (i = 0; i < len; i++) w[i] = w[i] | 0;
	w[len - 2] = n * 8;

	var a = 1732584193, b = -271733879, c = -1732584194, d = 271733878;
	for (i = 0; i < len; i += 16) {
		var oa = a, ob = b, oc = c, od = d;
		a = ff(a, b, c, d, w[i], 7, -680876936); d = ff(d, a, b, c, w[i+1], 12, -389564586);
		c = ff(c, d, a, b, w[i+2], 17, 606105819); b = ff(b, c, d, a, w[i+3], 22, -1044525330);
		a = ff(a, b, c, d, w[i+4], 7, -176418897); d = ff(d, a, b, c, w[i+5], 12, 1200080426);
		c = ff(c, d, a, b, w[i+6], 17, -1473231341); b = ff(b, c, d, a, w[i+7], 22, -45705983);
		a = ff(a, b, c, d, w[i+8], 7, 1770035416); d = ff(d, a, b, c, w[i+9], 12, -1958414417);
		c = ff(c, d, a, b, w[i+10], 17, -42063); b = ff(b, c, d, a, w[i+11], 22, -1990404162);
		a = ff(a, b, c, d, w[i+12], 7, 1804603682); d = ff(d, a, b, c, w[i+13], 12, -40341101);
		c = ff(c, d, a, b, w[i+14], 17, -1502002290); b = ff(b, c, d, a, w[i+15], 22, 1236535329);
		a = gg(a, b, c, d, w[i+1], 5, -165796510); d = gg(d, a, b, c, w[i+6], 9, -1069501632);
		c = gg(c, d, a, b, w[i+11], 14, 643717713); b = gg(b, c, d, a, w[i], 20, -373897302);
		a = gg(a, b, c, d, w[i+5], 5, -701558691); d = gg(d, a, b, c, w[i+10], 9, 38016083);
		c = gg(c, d, a, b, w[i+15], 14, -660478335); b = gg(b, c, d, a, w[i+4], 20, -405537848);
		a = gg(a, b, c, d, w[i+9], 5, 568446438); d = gg(d, a, b, c, w[i+14], 9, -1019803690);
		c = gg(c, d, a, b, w[i+3], 14, -187363961); b = gg(b, c, d, a, w[i+8], 20, 1163531501);
		a = gg(a, b, c, d, w[i+13], 5, -1444681467); d = gg(d, a, b, c, w[i+2], 9, -51403784);
		c = gg(c, d, a, b, w[i+7], 14, 1735328473); b = gg(b, c, d, a, w[i+12], 20, -1926607734);
		a = hh(a, b, c, d, w[i+5], 4, -378558); d = hh(d, a, b, c, w[i+8], 11, -2022574463);
		c = hh(c, d, a, b, w[i+11], 16, 1839030562); b = hh(b, c, d, a, w[i+14], 23, -35309556);
		a = hh(a, b, c, d, w[i+1], 4, -1530992060); d = hh(d, a, b, c, w[i+4], 11, 1272893353);
		c = hh(c, d, a, b, w[i+7], 16, -155497632); b = hh(b, c, d, a, w[i+10], 23, -1094730640);
		a = hh(a, b, c, d, w[i+13], 4, 681279174); d = hh(d, a, b, c, w[i], 11, -358537222);
		c = hh(c, d, a, b, w[i+3], 16, -722521979); b = hh(b, c, d, a, w[i+6], 23, 76029189);
		a = hh(a, b, c, d, w[i+9], 4, -640364487); d = hh(d, a, b, c, w[i+12], 11, -421815835);
		c = hh(c, d, a, b, w[i+15], 16, 530742520); b = hh(b, c, d, a, w[i+2], 23, -995338651);
		a = ii(a, b, c, d, w[i], 6, -198630844); d = ii(d, a, b, c, w[i+7], 10, 1126891415);
		c = ii(c, d, a, b, w[i+14], 15, -1416354905); b = ii(b, c, d, a, w[i+5], 21, -57434055);
		a = ii(a, b, c, d, w[i+12], 6, 1700485571); d = ii(d, a, b, c, w[i+3], 10, -1894986606);
		c = ii(c, d, a, b, w[i+10], 15, -1051523); b = ii(b, c, d, a, w[i+1], 21, -2054922799);
		a = ii(a, b, c, d, w[i+8], 6, 1873313359); d = ii(d, a, b, c, w[i+15], 10, -30611744);
		c = ii(c, d, a, b, w[i+6], 15, -1560198380); b = ii(b, c, d, a, w[i+13], 21, 1309151649);
		a = ii(a, b, c, d, w[i+4], 6, -145523070); d = ii(d, a, b, c, w[i+11], 10, -1120210379);
		c = ii(c, d, a, b, w[i+2], 15, 718787259); b = ii(b, c, d, a, w[i+9], 21, -343485551);
		a = add(a, oa); b = add(b, ob); c = add(c, oc); d = add(d, od);
	}

	var hex = '0123456789abcdef', out = '', v = [a, b, c, d];
	for (i = 0; i < 16; i++) out += hex.charAt((v[i >> 2] >> ((i % 4) * 8 + 4)) & 15) + hex.charAt((v[i >> 2] >> ((i % 4) * 8)) & 15);
	return out;
}

/* UTF-8 encode so non-ASCII passwords hash the same bytes the router stores. */
function utf8Bytes(s) {
	return unescape(encodeURIComponent(s));
}
