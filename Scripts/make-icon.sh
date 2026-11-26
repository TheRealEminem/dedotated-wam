#!/bin/bash
# Rebuilds Resources/AppIcon.icns from Resources/AppIcon.svg. Needs rsvg-convert (brew install librsvg).
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
set="$work/AppIcon.iconset"
mkdir -p "$set"
for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" Resources/AppIcon.svg -o "$set/icon_${size}x${size}.png"
  double=$((size * 2))
  rsvg-convert -w "$double" -h "$double" Resources/AppIcon.svg -o "$set/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$set" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
