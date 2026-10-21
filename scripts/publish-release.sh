#!/bin/sh
# Publish a release from dist/ and keep every older release's feed current.
#
#   scripts/publish-release.sh <version> <notes.md>
#   e.g. scripts/publish-release.sh 0.9.0 /tmp/notes-0.9.0.md
#
# 1. checks that dist/<release>/ holds signed feeds of <version> (opkg and apk);
# 2. creates release v<version> with those files and marks it Latest
#    (or replaces its files when it exists already);
# 3. uploads the same packages and indexes into every older release, so a
#    router set up with an older, versioned feed URL sees the update too, and
#    puts a "superseded" note on top of those releases;
# 4. downloads the indexes again from every feed URL and checks the version.
#
# Needs the GitHub CLI logged in (GH=/path/to/gh if it is not on PATH) and
# curl. Build dist/ first with scripts/build-packages.sh <release>.
set -eu

V=${1:?usage: $0 <version> <notes.md>}
NOTES=${2:?usage: $0 <version> <notes.md>}
GH=${GH:-gh}
cd "$(dirname "$0")/.."

[ -f "$NOTES" ] || { echo "notes file $NOTES not found" >&2; exit 1; }
REPO=$("$GH" repo view --json nameWithOwner -q .nameWithOwner)
TAG="v$V"

# --- 1. what to publish -------------------------------------------------------
FILES=""
for d in dist/*/; do
	for f in "$d"*; do
		[ -f "$f" ] || continue
		case "$(basename "$f")" in index.json) continue ;; esac
		FILES="$FILES $f"
	done
done

dups=$(for f in $FILES; do basename "$f"; done | sort | uniq -d)
[ -z "$dups" ] || { echo "the same file name in two feeds: $dups" >&2; exit 1; }

need() { for f in $FILES; do case "$(basename "$f")" in $1) return 0 ;; esac; done; echo "missing in dist/: $1" >&2; exit 1; }
need "wrt-hotspot_${V}-r*_all.ipk"	# 24.10 (opkg) feed
need "Packages"
need "Packages.gz"
need "Packages.sig"
need "wrt-hotspot-${V}-r*.apk"		# 25.12 (apk) feed
need "packages.adb"
need "wrthotspot.pem"

for f in $FILES; do
	case "$(basename "$f")" in
	*.ipk|*.apk)
		case "$(basename "$f")" in *"${V}-r"*) ;; *) echo "not version $V: $f" >&2; exit 1 ;; esac ;;
	esac
done

grep -q "^Version: ${V}-r" "$(for f in $FILES; do case "$f" in */Packages) echo "$f" ;; esac; done)" ||
	{ echo "the opkg index does not list version $V" >&2; exit 1; }

echo "== $TAG: $(echo $FILES | wc -w) files"

# --- 2. the release itself ------------------------------------------------------
if "$GH" release view "$TAG" >/dev/null 2>&1; then
	"$GH" release upload "$TAG" $FILES --clobber
	"$GH" release edit "$TAG" --notes-file "$NOTES" --latest
else
	"$GH" release create "$TAG" $FILES --title "WrtHotspot $V" --notes-file "$NOTES" --latest
fi

# --- 3. every older release serves the new feed too -------------------------------
FEED_FILES=""
for f in $FILES; do
	case "$(basename "$f")" in
	*.ipk|*.apk|Packages|Packages.gz|Packages.sig|Packages.manifest|Packages.bom.cdx.json|packages.adb) FEED_FILES="$FEED_FILES $f" ;;
	esac
done

BANNER="> **Superseded by [$V](https://github.com/$REPO/releases/tag/$TAG).** This release's feed URL also serves $V, so routers set up with it get the update with \`apk upgrade\` / \`opkg upgrade\`. New installs should use the \`releases/latest/download/\` URLs from the [README](https://github.com/$REPO#install)."
TMP=$(mktemp)

for old in $("$GH" release list --limit 100 --json tagName -q '.[].tagName'); do
	[ "$old" = "$TAG" ] && continue
	echo "== $old: feed -> $V"
	"$GH" release upload "$old" $FEED_FILES --clobber
	# Replace an earlier "Superseded" note, keep the rest of the notes.
	{ echo "$BANNER"; echo; "$GH" release view "$old" --json body -q .body | sed '/^> \*\*Superseded by/,/^$/d'; } > "$TMP"
	"$GH" release edit "$old" --notes-file "$TMP"
done
rm -f "$TMP"

# --- 4. check what routers will download ---------------------------------------------
# Byte for byte the signed indexes in dist/ (packages.adb is compressed, so
# its content cannot be grepped for the version).
fail=0
local_file() { for f in $FILES; do case "$f" in */"$1") echo "$f" ;; esac; done; }
sum() { sha256sum | cut -d' ' -f1; }
WANT_OPKG=$(sum < "$(local_file Packages)")
WANT_APK=$(sum < "$(local_file packages.adb)")
check() {	# check <base url>
	if [ "$(curl -fsSL "$1/Packages" | sum)" = "$WANT_OPKG" ] &&
	   [ "$(curl -fsSL "$1/packages.adb" | sum)" = "$WANT_APK" ]; then
		echo "   ok   $1"
	else
		echo "   FAIL $1 does not serve the $V indexes" >&2; fail=1
	fi
}
echo "== feed URLs"
check "https://github.com/$REPO/releases/latest/download"
for t in $("$GH" release list --limit 100 --json tagName -q '.[].tagName'); do
	check "https://github.com/$REPO/releases/download/$t"
done
[ $fail = 0 ] && echo "== every feed URL serves $V"
exit $fail
