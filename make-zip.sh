#!/bin/bash
# Packages FastScan.app as FastScan.zip: a zip that contains just the app, for
# attaching to a GitHub release, so people download one small file instead of
# the whole repository.
#
# ditto keeps the app's permissions and code signature intact (plain `zip`
# doesn't reliably). The app's files carry macOS "provenance" extended
# attributes, which Finder's Compress would turn into a __MACOSX folder inside
# the zip, so they're deliberately left out.
#
# Run it after ./build.sh, then attach FastScan.zip to the release. It's
# git-ignored, so it never gets committed.
set -euo pipefail
cd "$(dirname "$0")"

rm -f FastScan.zip
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl FastScan.app FastScan.zip

# Check what was made, so a bad zip never reaches a release: nothing but the app
# in it, and the app still valid, with its executables still executable, after
# being unzipped.
stray="$(unzip -Z1 FastScan.zip | grep -v '^FastScan\.app/' || true)"
if [ -n "$stray" ]; then
	echo "Unexpected entries in the zip:" >&2
	echo "$stray" >&2
	exit 1
fi

check="$(mktemp -d)"
trap 'rm -rf "$check"' EXIT
ditto -x -k FastScan.zip "$check"

codesign --verify --deep --strict "$check/FastScan.app"
test -x "$check/FastScan.app/Contents/MacOS/applet"
test -x "$check/FastScan.app/Contents/Resources/ax-menu"
test "$(codesign -dvvv FastScan.app 2>&1 | grep '^CDHash=')" = "$(codesign -dvvv "$check/FastScan.app" 2>&1 | grep '^CDHash=')"

echo "FastScan.zip: $(du -h FastScan.zip | cut -f1), $(unzip -Z1 FastScan.zip | grep -vc '/$') files, all inside FastScan.app; still valid and identical after unzipping."
