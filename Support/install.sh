#!/bin/sh
# Builds Release, installs it to /Applications and relaunches it. Siri and Shortcuts need a
# team-signed app, and only one registered copy, so the build folder copies are unregistered.
set -e
cd "$(dirname "$0")/.."
: "${DEVELOPER_DIR:=/Applications/Xcode 27.1.app/Contents/Developer}"
export DEVELOPER_DIR
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

xcodebuild -project MessengerMac.xcodeproj -scheme MessengerMac -configuration Release \
    -derivedDataPath build/DerivedData build 2>&1 | grep -E "error: |\*\* BUILD"
BUILT=build/DerivedData/Build/Products/Release/MessengerMac.app
codesign --verify --strict "$BUILT"

pkill -x MessengerMac && sleep 1 || true
rm -rf /Applications/MessengerMac.app
ditto "$BUILT" /Applications/MessengerMac.app
for copy in build/DerivedData/Build/Products/*/MessengerMac.app; do
    "$LSREGISTER" -u "$copy" 2>/dev/null || true
done
"$LSREGISTER" -f /Applications/MessengerMac.app
open /Applications/MessengerMac.app
# Siri keeps the app's old actions until its daemon restarts (launchd starts it again).
killall intelligenceflowd 2>/dev/null || true
