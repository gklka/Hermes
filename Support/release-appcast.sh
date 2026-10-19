#!/bin/sh
# Writes build/appcast.xml for a release: Sparkle's feed (the app reads the latest GitHub
# release's appcast.xml, Info.plist's SUFeedURL). After building Release and the DMG:
#   Support/release-appcast.sh build/Hermes-0.3.dmg
#   gh release create v0.3 build/Hermes-0.3.dmg build/appcast.xml …
# The DMG is signed with Sparkle's private key from this Mac's login Keychain (made once with
# Sparkle's generate_keys; its public key is Info.plist's SUPublicEDKey).
set -e
cd "$(dirname "$0")/.."
DMG="$1"
if [ ! -f "$DMG" ]; then
    echo "usage: $0 build/Hermes-<version>.dmg" >&2
    exit 1
fi
BIN=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
PLIST=build/DerivedData/Build/Products/Release/Hermes.app/Contents/Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$PLIST")
# sparkle:edSignature="…" length="…"
SIGNATURE=$("$BIN/sign_update" "$DMG")
URL="https://github.com/gklka/Hermes/releases/download/v$VERSION/$(basename "$DMG")"
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat > build/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Hermes</title>
    <item>
      <title>Hermes $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <link>https://github.com/gklka/Hermes/releases/tag/v$VERSION</link>
      <enclosure url="$URL" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
EOF
echo "build/appcast.xml: Hermes $VERSION ($BUILD), $URL"
