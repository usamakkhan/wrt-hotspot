#!/bin/sh
# Build the WrtHotspot packages with the official OpenWrt SDK.
#
#   scripts/build-packages.sh <release> [work-dir]
#   e.g. scripts/build-packages.sh 24.10.4      -> dist/24.10.4/*.ipk
#        scripts/build-packages.sh 25.12.5      -> dist/25.12.5/*.apk
#
# All packages are architecture independent (ucode, JS, HTML), so the x86-64
# SDK builds packages that install on every target of that release.
# Needs: a Linux host with the SDK prerequisites (build-essential, gawk,
# gettext, git, libncurses-dev, python3, rsync, unzip, zstd, wget/curl).
set -eu

RELEASE=${1:?usage: $0 <release> [work-dir]}
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${2:-$REPO/build}
BASE="https://downloads.openwrt.org/releases/$RELEASE/targets/x86/64"
OUT="$REPO/dist/$RELEASE"

mkdir -p "$WORK" "$OUT"
cd "$WORK"

fetch() { if command -v curl >/dev/null; then curl -fsSL "$1"; else wget -qO- "$1"; fi; }

# The SDK file name carries the toolchain version: look it up.
SDK=$(fetch "$BASE/sha256sums" | sed -n 's/.*\*\{0,1\}\(openwrt-sdk-[^ ]*\.tar\.\(zst\|xz\)\)$/\1/p' | head -1)
[ -n "$SDK" ] || { echo "no SDK found for $RELEASE at $BASE" >&2; exit 1; }
DIR="$WORK/${SDK%.tar.*}"

if [ ! -d "$DIR" ]; then
	echo "== downloading $SDK"
	fetch "$BASE/$SDK" > "$SDK"
	SUM=$(fetch "$BASE/sha256sums" | grep " \*\{0,1\}$SDK\$" | cut -d' ' -f1)
	echo "$SUM  $SDK" | sha256sum -c -
	case "$SDK" in
		*.zst) tar --zstd -xf "$SDK" ;;
		*) tar -xJf "$SDK" ;;
	esac
	rm -f "$SDK"
fi

cd "$DIR"

# Our feed, plus luci (luci.mk) and base (lua): the LuCI app needs the
# luci-base host tools to build. Nothing is compiled for the target besides
# our own packages: they are data only, so NO_DEPS=1 skips their runtime
# dependencies (tc-full, uhttpd, luci-base, ...), which the router installs.
grep -qs '^src-link wrthotspot ' feeds.conf || {
	cp feeds.conf.default feeds.conf
	echo "src-link wrthotspot $REPO/feed" >> feeds.conf
}

echo "== feeds"
# A re-run cannot "git pull" the pinned base feed: rely on the index files instead.
./scripts/feeds update wrthotspot base luci >/dev/null 2>&1 || true
for f in wrthotspot base luci; do [ -s feeds/$f.index ] || { echo "feed $f missing" >&2; exit 1; }; done
./scripts/feeds install -p wrthotspot -a >/dev/null 2>&1
./scripts/feeds install lua luci-base >/dev/null 2>&1

make defconfig >/dev/null

build() {	# build <log name> <make args...>
	name=$1; shift
	make "$@" V=s -j"$(nproc)" > "$WORK/build-$RELEASE-$name.log" 2>&1 || {
		echo "build of $name failed, see $WORK/build-$RELEASE-$name.log" >&2
		tail -30 "$WORK/build-$RELEASE-$name.log" >&2
		exit 1
	}
}

echo "== host tools"
build host-tools package/lua/host/compile package/luci-base/host/compile

echo "== building"
rm -rf bin/packages/*/wrthotspot "$OUT"/*
for p in wrt-hotspot wrt-hotspot-panel luci-app-wrt-hotspot; do
	build "$p" "package/$p/compile" NO_DEPS=1
done

find bin/packages -path '*wrthotspot*' \( -name '*.ipk' -o -name '*.apk' \) -exec cp {} "$OUT/" \;
echo "== packages in $OUT"
ls -l "$OUT"
