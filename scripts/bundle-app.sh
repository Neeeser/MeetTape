#!/bin/bash
# Assembles MeetTape.app from the SwiftPM products.
#
# This machine has Command Line Tools only, so there is no xcodebuild and no
# Xcode project; the bundle is built here instead. Signing is ad-hoc by default,
# which is enough to hold TCC grants for one build. Set MEETTAPE_SIGN_IDENTITY to
# a Developer ID Application identity for a distributable build.
#
# Usage: scripts/bundle-app.sh [debug|release]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=spm-env.sh
source "$REPO_ROOT/scripts/spm-env.sh"

CONFIG="${1:-release}"
VERSION="$(cat "$REPO_ROOT/VERSION" 2>/dev/null || echo "0.1.0")"
BUILD_NUMBER="${MEETTAPE_BUILD_NUMBER:-1}"
BUNDLE_ID="com.meettape.app"
APP_DIR="$REPO_ROOT/dist/MeetTape.app"
BIN_DIR="$REPO_ROOT/.build/$CONFIG"

cd "$REPO_ROOT"
echo "==> building ($CONFIG)"
swift build --configuration "$CONFIG" --product MeetTape
swift build --configuration "$CONFIG" --product meettape-nativehost

echo "==> building the browser extension"
"$REPO_ROOT/extension/build.sh" >/dev/null

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/MeetTape" "$APP_DIR/Contents/MacOS/MeetTape"
# The native messaging host sits next to the app executable so the installer can
# copy it to a stable absolute path outside any TCC-protected directory.
cp "$BIN_DIR/meettape-nativehost" "$APP_DIR/Contents/MacOS/meettape-nativehost"
cp -R "$REPO_ROOT/extension/dist" "$APP_DIR/Contents/Resources/extension"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>MeetTape</string>
    <key>CFBundleDisplayName</key>
    <string>MeetTape</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>MeetTape</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MeetTape</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>MeetTape records your side of meetings.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>MeetTape matches recordings to calendar events for titles and attendees.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>MeetTape matches recordings to calendar events for titles and attendees.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>MeetTape reads window titles to tell which meeting is on screen.</string>
</dict>
</plist>
PLIST

cat > "$APP_DIR/Contents/Resources/MeetTape.entitlements" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Mandatory under the hardened runtime. Without it the microphone request
         is denied instantly with no dialog, which looks exactly like a user
         denial and is easy to misdiagnose. -->
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.personal-information.calendars</key>
    <true/>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
ENTITLEMENTS

IDENTITY="${MEETTAPE_SIGN_IDENTITY:--}"
echo "==> signing with identity: $IDENTITY"
codesign --force --sign "$IDENTITY" \
    --options runtime \
    --timestamp=none \
    "$APP_DIR/Contents/MacOS/meettape-nativehost"
codesign --force --sign "$IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    --entitlements "$APP_DIR/Contents/Resources/MeetTape.entitlements" \
    --timestamp=none \
    "$APP_DIR"

codesign --verify --verbose=1 "$APP_DIR" 2>&1 | sed 's/^/    /'
echo "==> built $APP_DIR"
if [ "$IDENTITY" = "-" ]; then
    cat <<'NOTE'

    Signed ad-hoc. TCC pins its grants to the code hash, so every rebuild
    invalidates Microphone, Accessibility and Screen Recording and they have to
    be granted again. A Developer ID signature keeps a stable designated
    requirement and does not have this problem.
NOTE
fi
