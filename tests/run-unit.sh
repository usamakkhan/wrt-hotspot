#!/bin/sh
# Run the ucode unit tests. Needs `ucode` with the fs module (any OpenWrt
# 24.10+ system, or ucode built on Linux).
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/feed/net/wrt-hotspot/files/usr/share/ucode"
fail=0
for t in "$ROOT"/tests/unit/test_*.uc; do
	if ucode -L "$LIB/*.uc" -L "$ROOT/tests/unit/*.uc" "$t"; then :; else fail=1; fi
done
[ $fail = 0 ] && echo "ALL UNIT TESTS PASSED" || { echo "UNIT TESTS FAILED"; exit 1; }
