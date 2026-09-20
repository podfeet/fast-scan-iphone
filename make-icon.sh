#!/bin/bash
# Regenerates the app icon (fast-scan-iphone-icon.png, AppIcon.iconset and
# AppIcon.icns) from icon-source.svg, with transparent rounded corners.
#
# Quick Look is the renderer here that handles the SVG's blur filter, but it
# composites onto opaque white, which is what produced white corners. So the
# artwork is rendered once over white and once over black, and icon-matte.swift
# recovers the exact transparency from the pair.
#
# Run build.sh afterwards to put the new icon into FastScan.app.
set -euo pipefail
cd "$(dirname "$0")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for background in white black; do
	# The background rect goes first inside the SVG, right after <defs>.
	sed "s#</defs>#</defs>\n  <rect width=\"1024\" height=\"1024\" fill=\"$background\"/>#" icon-source.svg > "$work/on-$background.svg"
	# qlmanage can hang, so don't let it wait forever.
	perl -e 'alarm 60; exec @ARGV' qlmanage -t -s 1024 -o "$work" "$work/on-$background.svg" > /dev/null
done

swiftc -O icon-matte.swift -o "$work/icon-matte"
"$work/icon-matte" "$work/on-white.svg.png" "$work/on-black.svg.png" AppIcon.iconset fast-scan-iphone-icon.png

iconutil -c icns AppIcon.iconset -o AppIcon.icns
echo "AppIcon.icns rebuilt"
