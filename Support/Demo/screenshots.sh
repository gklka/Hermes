#!/bin/sh
# Takes the website's screenshots (docs/images) from the app in demo mode, on made-up chats.
#
#     Support/Demo/screenshots.sh [scene …]
#
# Builds a separate copy of the app (its own bundle ID, signed to run locally, so it shares no
# settings or data with the real one), then runs capture.py. Needs Python 3 with Pillow, and the
# Screen Recording permission for the terminal. The demo app comes to the front while it runs.
set -e
cd "$(dirname "$0")/../.."
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

xcodebuild -project Hermes.xcodeproj -scheme Hermes -configuration Release \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build/DemoDerivedData \
    BUNDLE_ID_PREFIX=demo.hermes CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_ENTITLEMENTS= ENABLE_HARDENED_RUNTIME=NO \
    build 2>&1 | grep -E "error: |\*\* BUILD"
APP=build/DemoDerivedData/Build/Products/Release/Hermes.app

python3 Support/Demo/capture.py "$APP" "$@"

# Only the real app stays registered (Shortcuts and Siri would offer both).
"$LSREGISTER" -u "$APP" 2>/dev/null || true
