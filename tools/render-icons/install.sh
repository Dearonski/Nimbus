#!/bin/sh
# Regenerates every icon asset from the app's shapes and drops it into the catalogs.
set -e
root=$(cd "$(dirname "$0")/../.." && pwd)
out=$(mktemp -d)
xcrun swiftc -swift-version 6 -O \
  "$root/Nimbus/Components/NimbusMark.swift" \
  "$root/Nimbus/App/Theme.swift" \
  "$root/tools/render-icons/main.swift" -o "$out/rendericon"
"$out/rendericon" "$out"

icons="$root/Nimbus/Assets.xcassets/AppIcon.appiconset"
cp "$out/icon_16.png"   "$icons/icon_16x16.png"
cp "$out/icon_32.png"   "$icons/icon_16x16@2x.png"
cp "$out/icon_32.png"   "$icons/icon_32x32.png"
cp "$out/icon_64.png"   "$icons/icon_32x32@2x.png"
cp "$out/icon_128.png"  "$icons/icon_128x128.png"
cp "$out/icon_256.png"  "$icons/icon_128x128@2x.png"
cp "$out/icon_256.png"  "$icons/icon_256x256.png"
cp "$out/icon_512.png"  "$icons/icon_256x256@2x.png"
cp "$out/icon_512.png"  "$icons/icon_512x512.png"
cp "$out/icon_1024.png" "$icons/icon_512x512@2x.png"

menubar="$root/Nimbus/Assets.xcassets/MenuBarMark.imageset"
cp "$out/menubar_16.png" "$out/menubar_32.png" "$menubar/"

rm -rf "$out"
echo "icons regenerated"
