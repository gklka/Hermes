#!/bin/sh
# Builds a release: archives Release universal, exports it signed with Developer ID, notarizes
# and staples the app and its DMG, and writes build/appcast.xml. Then publish with
#   gh release create v<version> build/Hermes-<version>.dmg build/appcast.xml …
# Needs:
# - the paid team (DEVELOPMENT_TEAM, Signing.local.xcconfig) in Xcode's accounts: the export
#   signs with its cloud-managed Developer ID certificate (-allowProvisioningUpdates);
# - notarytool's credentials in the Keychain as "hermes-notary" (NOTARY_PROFILE for another name):
#     xcrun notarytool store-credentials hermes-notary --apple-id <Apple ID> --team-id <team>
# - the changelog in build/Hermes-<version>.md;
# - Sparkle's private key in the login Keychain (release-appcast.sh).
set -e
cd "$(dirname "$0")/.."
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
PROFILE=${NOTARY_PROFILE:-hermes-notary}
TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Support/Signing.local.xcconfig)
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "No notarytool credentials named $PROFILE: run" >&2
    echo "  xcrun notarytool store-credentials $PROFILE --apple-id <Apple ID> --team-id $TEAM" >&2
    exit 1
fi

ARCHIVE=build/Hermes.xcarchive
EXPORT=build/export
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project Hermes.xcodeproj -scheme Hermes -configuration Release \
    -destination generic/platform=macOS -derivedDataPath build/DerivedData \
    -archivePath "$ARCHIVE" -allowProvisioningUpdates archive 2>&1 | grep -E "error: |\*\* ARCHIVE"
[ -d "$ARCHIVE" ] || exit 1

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$ARCHIVE/Products/Applications/Hermes.app/Contents/Info.plist")
NOTES=build/Hermes-$VERSION.md
DMG=build/Hermes-$VERSION.dmg
if [ ! -s "$NOTES" ]; then
    echo "Write the changelog in $NOTES first" >&2
    exit 1
fi

# Developer ID export re-signs everything inside, Sparkle's helpers too, with a timestamp.
cat > build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM</string>
    <key>destination</key><string>export</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist build/ExportOptions.plist -allowProvisioningUpdates 2>&1 | grep -E "error: |\*\* EXPORT"
APP=$EXPORT/Hermes.app
codesign --verify --deep --strict "$APP"
IDENTITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)/\1/p' | head -1)
if [ -z "$IDENTITY" ]; then
    echo "Hermes.app isn't signed for Developer ID" >&2
    exit 1
fi

# Submits a file to Apple's notary service and fails unless it's accepted.
notarize() {
    RESULT=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json)
    echo "$RESULT"
    if ! echo "$RESULT" | grep -q '"status":"Accepted"'; then
        ID=$(echo "$RESULT" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
        [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE"
        exit 1
    fi
}

ditto -c -k --keepParent "$APP" build/Hermes-notarize.zip
notarize build/Hermes-notarize.zip
rm build/Hermes-notarize.zip
xcrun stapler staple "$APP"

rm -rf build/dmg "$DMG"
mkdir build/dmg
ditto "$APP" build/dmg/Hermes.app
ln -s /Applications build/dmg/Applications
hdiutil create -volname Hermes -srcfolder build/dmg -format UDZO -ov "$DMG" >/dev/null
rm -rf build/dmg
# The export signs with a cloud-managed certificate; the DMG can only be signed with a local one.
if security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
    codesign --sign "$IDENTITY" --timestamp "$DMG"
fi
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG" || true
spctl --assess --type execute -v "$APP"

APP="$APP" Support/release-appcast.sh "$DMG" "$NOTES"
echo "$DMG SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
