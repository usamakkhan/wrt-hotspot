// Report whether a live host is allowed through a bypass binding. Match the
// same server, MAC and address conditions used by the nftables rules.
'use strict';

function address_matches(cidr, ip) {
	let parts = split(cidr, '/');
	let network = iptoarr(parts[0]), address = iptoarr(ip);

	if (!network || !address || length(network) != length(address))
		return false;

	let bits = (parts[1] != null) ? int(parts[1]) : length(network) * 8;
	for (let i = 0; i < length(network) && bits > 0; i++, bits -= 8) {
		let mask = (bits >= 8) ? 0xff : (0xff << (8 - bits)) & 0xff;
		if ((network[i] & mask) != (address[i] & mask))
			return false;
	}

	return true;
}

export function matches(binding, host, ip) {
	if (binding.server && binding.server != 'all' && binding.server != host.server)
		return false;
	if (binding.mac && binding.mac != host.mac)
		return false;
	return !binding.address || address_matches(binding.address.cidr, ip);
};

export function bypassed(host, bindings) {
	let addresses = [ ...(host.ipv4 ?? []), ...(host.ipv6 ?? []) ];

	// An address binding can only apply to an address actually seen on this
	// host. Blocked rules take priority over bypassed rules in the dataplane.
	for (let ip in addresses) {
		if (length(filter(bindings, (b) => b.type == 'blocked' && matches(b, host, ip))))
			continue;
		if (length(filter(bindings, (b) => b.type == 'bypassed' && matches(b, host, ip))))
			return true;
	}

	return false;
};
