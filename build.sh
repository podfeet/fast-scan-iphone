#!/bin/bash
# Rebuilds FastScan.app, then resets the permission grants that the rebuild
# invalidates: every rebuild gets a new ad-hoc code signature, so macOS forgets
# the previous approvals.
#
# The finished app is self-contained: the helpers (click-helper.js,
# escape-helper.js and the ax-menu binary) are copied into its Resources, so it
# can be copied anywhere (Applications, say) and this folder is only needed to
# rebuild it, not to run it.
#
# Afterwards: click the app, approve the "control System Events" and "control
# Finder" prompts, flip to the "not allowed assistive access" error that opens
# behind the Finder window
# and cancel it, switch FastScan.app on under System Settings > Privacy &
# Security > Device Control & Data Access, then click the button again.
set -euo pipefail
cd "$(dirname "$0")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The helper goes first so a compile error stops the build before the app (or its
# permissions) are touched. It's built for both Apple silicon and Intel, and for
# macOS 13 and later, so the finished app also runs on a Mac other than this one
# (the default is this Mac's architecture and exact OS version). selftest only
# checks the item-picking logic against mock menus; it doesn't touch the UI.
swiftc -O -target arm64-apple-macos13.0 ax-menu.swift -o "$work/ax-menu-arm64"
swiftc -O -target x86_64-apple-macos13.0 ax-menu.swift -o "$work/ax-menu-x86_64"
lipo -create "$work/ax-menu-arm64" "$work/ax-menu-x86_64" -output ax-menu
codesign --force --sign - ax-menu
./ax-menu selftest

osacompile -o "FastScan.app/Contents/Resources/Scripts/main.scpt" scan-from-iphone.applescript

# Ship the helpers inside the app, where the script looks for them.
cp click-helper.js escape-helper.js ax-menu "FastScan.app/Contents/Resources/"
chmod +x "FastScan.app/Contents/Resources/ax-menu"

# Put the custom icon in. osacompile leaves CFBundleIconName pointing at a
# stock icon in Assets.car, and macOS prefers that over CFBundleIconFile, so
# the custom icon never shows unless both are removed. (Regenerate the icon
# itself from icon-source.svg with make-icon.sh.)
plutil -remove CFBundleIconName "FastScan.app/Contents/Info.plist" 2>/dev/null || true
rm -f "FastScan.app/Contents/Resources/Assets.car"
cp AppIcon.icns "FastScan.app/Contents/Resources/AppIcon.icns"

xattr -cr "FastScan.app"
codesign --force --sign - --identifier com.podfeet.fastscaniphone "FastScan.app"

# LaunchServices keeps its own copy of the app's Info.plist and only re-reads
# it when the bundle folder's modification date changes, which a rebuild never
# does, so it would keep showing the old icon. Touch the bundle and force it
# to re-register.
touch "FastScan.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "FastScan.app"

tccutil reset Accessibility com.podfeet.fastscaniphone
tccutil reset AppleEvents com.podfeet.fastscaniphone
