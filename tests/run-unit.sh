#!/bin/sh
# Run the ucode unit tests. Needs `ucode` with the fs module (any OpenWrt
# 24.10+ system, or ucode built on Linux). If `nft` is present, the generated
# ruleset is also checked by nftables itself (nft -c, nothing is applied).
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/feed/net/wrt-hotspot/files/usr/share/ucode"
fail=0
for t in "$ROOT"/tests/unit/test_*.uc; do
	if ucode -L "$LIB/*.uc" -L "$ROOT/tests/unit/*.uc" "$t"; then :; else fail=1; fi
done

if command -v nft >/dev/null; then
	gen=/tmp/wrthotspot-syntax.nft
	if ucode -L "$LIB/*.uc" "$ROOT/tests/unit/nft_syntax.uc" | sed '/^delete table/d' > $gen && [ -s $gen ] && out=$(nft -c -f $gen 2>&1); then
		echo "nft syntax: generated ruleset accepted by $(nft --version)"
	else
		echo "nft syntax: REJECTED"; echo "$out"; fail=1
	fi
	rm -f $gen
fi

[ $fail = 0 ] && echo "ALL UNIT TESTS PASSED" || { echo "UNIT TESTS FAILED"; exit 1; }
