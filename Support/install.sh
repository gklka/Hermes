#!/bin/sh
# Builds Release, installs it to /Applications and relaunches it. Siri and Shortcuts need a
# team-signed app, and only one registered copy, so the build folder copies are unregistered.
# Signing is automatic: Xcode makes the provisioning profile (-allowProvisioningUpdates), which
# communication notifications need.
set -e
cd "$(dirname "$0")/.."
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# By default build only for this Mac (fast). UNIVERSAL=1 builds a universal arm64 + x86_64 app
# (for releases, so Intel Macs can run it) by targeting a generic macOS destination.
if [ -n "$UNIVERSAL" ]; then
	DESTINATION="generic/platform=macOS"
else
	DESTINATION="platform=macOS,arch=$(uname -m)"
fi
# A failed build stops here: otherwise the last build's app (maybe much older) is installed.
# (Piping xcodebuild into grep would hide its exit status.)
BUILD_LOG=$(mktemp)
if xcodebuild -project Hermes.xcodeproj -scheme Hermes -configuration Release \
    -destination "$DESTINATION" \
    -derivedDataPath build/DerivedData -allowProvisioningUpdates build >"$BUILD_LOG" 2>&1; then
    BUILD_OK=1
else
    BUILD_OK=0
fi
grep -E "error: |\*\* BUILD" "$BUILD_LOG" || true
rm -f "$BUILD_LOG"
[ "$BUILD_OK" = 1 ] || { echo "Build failed: nothing installed." >&2; exit 1; }
BUILT=build/DerivedData/Build/Products/Release/Hermes.app
codesign --verify --strict "$BUILT"

pkill -x Hermes && sleep 1 || true
# The app used to be called MessengerMac: that copy goes (Hermes takes over its data at launch).
if [ -d /Applications/MessengerMac.app ]; then
    pkill -x MessengerMac && sleep 1 || true
    "$LSREGISTER" -u /Applications/MessengerMac.app 2>/dev/null || true
    rm -rf /Applications/MessengerMac.app
fi
rm -rf /Applications/Hermes.app
ditto "$BUILT" /Applications/Hermes.app
for copy in build/DerivedData/Build/Products/*/Hermes.app; do
    "$LSREGISTER" -u "$copy" 2>/dev/null || true
done
"$LSREGISTER" -f /Applications/Hermes.app
# QUIET=1 relaunches in the background without stealing focus (for development, so a relaunch
# doesn't interrupt what you're doing on the machine).
if [ -n "$QUIET" ]; then
    open -g /Applications/Hermes.app --args -QuietLaunch YES
else
    open /Applications/Hermes.app
fi
# Siri keeps the app's old actions until its daemon restarts (launchd starts it again).
killall intelligenceflowd 2>/dev/null || true
