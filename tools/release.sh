#!/bin/zsh
# A lasting self-made certificate, not ad-hoc: the keychain ties the sign-in to the signature.
#   tools/release.sh                   # signs with the "Nimbus Release" identity
#   IDENTITY=- tools/release.sh        # ad-hoc, to check the pipeline without the certificate
set -euo pipefail

cd "$(dirname "$0")/.."
IDENTITY=${IDENTITY:-"Nimbus Release"}
OUT=build/release
DERIVED=$OUT/derived

if [[ $IDENTITY != "-" ]] && ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "No code signing identity named \"$IDENTITY\" in the keychain." >&2
    echo "Keychain Access → Certificate Assistant → Create a Certificate…, type Code Signing." >&2
    exit 1
fi

VERSION=$(xcodebuild -project Nimbus.xcodeproj -scheme Nimbus -configuration Release -showBuildSettings 2>/dev/null |
    awk '$1 == "MARKETING_VERSION" { print $3 }')
rm -rf $OUT
mkdir -p $OUT

echo "Building Nimbus $VERSION…"
# Unsigned here: Xcode would ask for a development team, and the identity is not an Apple one.
xcodebuild -project Nimbus.xcodeproj -scheme Nimbus -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath $DERIVED \
    CODE_SIGNING_ALLOWED=NO build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

APP=$OUT/Nimbus.app
ditto $DERIVED/Build/Products/Release/Nimbus.app $APP

echo "Signing with \"$IDENTITY\"…"
codesign --force --sign "$IDENTITY" --entitlements Nimbus.entitlements --timestamp=none $APP
codesign --verify --strict $APP
codesign -d --entitlements - $APP 2>/dev/null | grep -q "app-sandbox" || { echo "Sandbox entitlement missing." >&2; exit 1; }

echo "Packing the disk image…"
STAGING=$OUT/dmg
mkdir -p $STAGING
ditto $APP $STAGING/Nimbus.app
ln -s /Applications $STAGING/Applications
DMG=$OUT/Nimbus-$VERSION.dmg
rm -f $DMG
# `hdiutil create` is deprecated from macOS 27 on; kept for a builder still on 26.
if diskutil image create from --help >/dev/null 2>&1; then
    diskutil image create from --format UDZO --volumeName "Nimbus $VERSION" $STAGING $DMG >/dev/null 2>&1
else
    hdiutil create -volname "Nimbus $VERSION" -srcfolder $STAGING -ov -format UDZO $DMG >/dev/null
fi
rm -rf $STAGING $DERIVED

echo "Done: $DMG"
shasum -a 256 $DMG
