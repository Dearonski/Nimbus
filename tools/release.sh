#!/bin/zsh
# A lasting self-made certificate, not ad-hoc: macOS keys what it has granted an app to its signature.
#   tools/release.sh                   # signs with the "Nimbus Release" identity
#   NOTES=notes.md tools/release.sh    # embeds these release notes in the update feed
#   IDENTITY=- tools/release.sh        # ad-hoc, to check the pipeline without the certificate
#   FEED_URL=… DOWNLOAD_PREFIX=… tools/release.sh   # a build that updates from a test feed
set -euo pipefail

cd "$(dirname "$0")/.."
IDENTITY=${IDENTITY:-"Nimbus Release"}
PUBLISHED_FEED=https://github.com/Dearonski/Nimbus/releases/latest/download/appcast.xml
FEED_URL=${FEED_URL:-$PUBLISHED_FEED}
OUT=build/release
DERIVED=$OUT/derived

if [[ $IDENTITY != "-" ]] && ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "No code signing identity named \"$IDENTITY\" in the keychain." >&2
    echo "Keychain Access → Certificate Assistant → Create a Certificate…, type Code Signing." >&2
    exit 1
fi

SETTINGS=$(xcodebuild -project Nimbus.xcodeproj -scheme Nimbus -configuration Release -showBuildSettings 2>/dev/null)
VERSION=$(awk '$1 == "MARKETING_VERSION" { print $3 }' <<< $SETTINGS)
BUILD=$(awk '$1 == "CURRENT_PROJECT_VERSION" { print $3 }' <<< $SETTINGS)
DOWNLOAD_PREFIX=${DOWNLOAD_PREFIX:-https://github.com/Dearonski/Nimbus/releases/download/v$VERSION/}

# Sparkle compares build numbers, not versions: one that did not grow is never offered.
PUBLISHED_BUILD=$(curl -fsL $PUBLISHED_FEED 2>/dev/null | sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' | sort -n | tail -1 || true)
if [[ $FEED_URL == $PUBLISHED_FEED && -n $PUBLISHED_BUILD && $BUILD -le $PUBLISHED_BUILD ]]; then
    echo "Build $BUILD is not above the published $PUBLISHED_BUILD — raise CURRENT_PROJECT_VERSION." >&2
    exit 1
fi

rm -rf $OUT
mkdir -p $OUT

echo "Building Nimbus $VERSION ($BUILD)…"
# Unsigned here: Xcode would ask for a development team, and the identity is not an Apple one.
xcodebuild -project Nimbus.xcodeproj -scheme Nimbus -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath $DERIVED \
    CODE_SIGNING_ALLOWED=NO build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

APP=$OUT/Nimbus.app
ditto $DERIVED/Build/Products/Release/Nimbus.app $APP
[[ $FEED_URL != $PUBLISHED_FEED ]] && /usr/libexec/PlistBuddy -c "Set :SUFeedURL $FEED_URL" $APP/Contents/Info.plist

echo "Signing with \"$IDENTITY\"…"
# Inside out, as Sparkle's own guide orders it; `--deep` would give every part the app's entitlements.
SPARKLE=$APP/Contents/Frameworks/Sparkle.framework
codesign -f -s "$IDENTITY" -o runtime --timestamp=none $SPARKLE/Versions/B/XPCServices/Installer.xpc
codesign -f -s "$IDENTITY" -o runtime --timestamp=none --preserve-metadata=entitlements $SPARKLE/Versions/B/XPCServices/Downloader.xpc
codesign -f -s "$IDENTITY" -o runtime --timestamp=none $SPARKLE/Versions/B/Autoupdate
codesign -f -s "$IDENTITY" -o runtime --timestamp=none $SPARKLE/Versions/B/Updater.app
codesign -f -s "$IDENTITY" -o runtime --timestamp=none $SPARKLE
codesign --force --sign "$IDENTITY" --entitlements Nimbus.entitlements --timestamp=none $APP
codesign --verify --strict --deep $APP
codesign -d --entitlements - $APP 2>/dev/null | grep -q "app-sandbox" || { echo "Sandbox entitlement missing." >&2; exit 1; }

echo "Packing the disk image…"
STAGING=$OUT/dmg
mkdir -p $STAGING
ditto $APP $STAGING/Nimbus.app
ln -s /Applications $STAGING/Applications
UPDATES=$OUT/updates
mkdir -p $UPDATES
DMG=$UPDATES/Nimbus-$VERSION.dmg
# `hdiutil create` is deprecated from macOS 27 on; kept for a builder still on 26.
if diskutil image create from --help >/dev/null 2>&1; then
    diskutil image create from --format UDZO --volumeName "Nimbus $VERSION" $STAGING $DMG >/dev/null 2>&1
else
    hdiutil create -volname "Nimbus $VERSION" -srcfolder $STAGING -ov -format UDZO $DMG >/dev/null
fi

echo "Writing the update feed…"
[[ -n ${NOTES:-} ]] && cp $NOTES $UPDATES/Nimbus-$VERSION.md
# The EdDSA key is read from the login keychain, where `generate_keys` put it.
$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast --embed-release-notes \
    --download-url-prefix $DOWNLOAD_PREFIX -o $OUT/appcast.xml $UPDATES
mv $DMG $OUT/
rm -rf $STAGING $UPDATES $DERIVED

echo "Done: $OUT/Nimbus-$VERSION.dmg and $OUT/appcast.xml"
shasum -a 256 $OUT/Nimbus-$VERSION.dmg
