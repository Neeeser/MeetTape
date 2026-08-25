#!/bin/bash
# Assembles Pipit.app from the SwiftPM products.
#
# This machine has Command Line Tools only, so there is no xcodebuild and no
# Xcode project; the bundle is built here instead. Signing is ad-hoc by default,
# which is enough to hold TCC grants for one build. Set PIPIT_SIGN_IDENTITY to
# a Developer ID Application identity for a distributable build.
#
# Usage: scripts/bundle-app.sh [debug|release]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=spm-env.sh
source "$REPO_ROOT/scripts/spm-env.sh"

CONFIG="${1:-release}"
VERSION="$(cat "$REPO_ROOT/VERSION" 2>/dev/null || echo "0.1.0")"
BUILD_NUMBER="${PIPIT_BUILD_NUMBER:-1}"
BUNDLE_ID="com.pipit.app"
APP_DIR="$REPO_ROOT/dist/Pipit.app"
BIN_DIR="$REPO_ROOT/.build/$CONFIG"

cd "$REPO_ROOT"
echo "==> building ($CONFIG)"
swift build --configuration "$CONFIG" "${PIPIT_SWIFT_FLAGS[@]+"${PIPIT_SWIFT_FLAGS[@]}"}" --product Pipit
swift build --configuration "$CONFIG" "${PIPIT_SWIFT_FLAGS[@]+"${PIPIT_SWIFT_FLAGS[@]}"}" --product pipit-nativehost

echo "==> building the browser extension"
"$REPO_ROOT/extension/build.sh" >/dev/null

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/Pipit" "$APP_DIR/Contents/MacOS/Pipit"
# The native messaging host sits next to the app executable so the installer can
# copy it to a stable absolute path outside any TCC-protected directory.
cp "$BIN_DIR/pipit-nativehost" "$APP_DIR/Contents/MacOS/pipit-nativehost"
cp -R "$REPO_ROOT/extension/dist" "$APP_DIR/Contents/Resources/extension"
cp "$REPO_ROOT/Assets/Pipit/AppIcons/Pipit.icns" "$APP_DIR/Contents/Resources/Pipit.icns"
for state in idle recording paused warning; do
    cp "$REPO_ROOT/Assets/Pipit/MenuBar/pipit-$state.png" "$APP_DIR/Contents/Resources/"
    cp "$REPO_ROOT/Assets/Pipit/MenuBar/pipit-$state@2x.png" "$APP_DIR/Contents/Resources/"
done

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Pipit</string>
    <key>CFBundleDisplayName</key>
    <string>Pipit</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>Pipit</string>
    <key>CFBundleIconFile</key>
    <string>Pipit.icns</string>
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
    <string>Pipit</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Pipit records your side of meetings.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Pipit matches recordings to calendar events for titles and attendees.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Pipit matches recordings to calendar events for titles and attendees.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Pipit saves your recordings and transcripts here.</string>
</dict>
</plist>
PLIST

cat > "$REPO_ROOT/dist/Pipit.entitlements" <<'ENTITLEMENTS'
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
</dict>
</plist>
ENTITLEMENTS

IDENTITY="${PIPIT_SIGN_IDENTITY:--}"
# A secure timestamp is mandatory for notarization; ad-hoc signing cannot have one.
if [ "$IDENTITY" = "-" ]; then
    TIMESTAMP=(--timestamp=none)
    echo "==> signing ad-hoc"
else
    TIMESTAMP=(--timestamp)
    echo "==> signing with a Developer ID identity"
fi
# A stable identifier is what lets the app recognise its own relay when the relay
# connects to the sensor socket.
codesign --force --sign "$IDENTITY" \
    --identifier "com.pipit.nativehost" \
    --options runtime \
    "${TIMESTAMP[@]}" \
    "$APP_DIR/Contents/MacOS/pipit-nativehost"
codesign --force --sign "$IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    --entitlements "$REPO_ROOT/dist/Pipit.entitlements" \
    "${TIMESTAMP[@]}" \
    "$APP_DIR"

codesign --verify --deep --strict --verbose=1 "$APP_DIR" 2>&1 | sed 's/^/    /'
echo "==> built $APP_DIR"
if [ "$IDENTITY" = "-" ]; then
    cat <<'NOTE'

    Signed ad-hoc. TCC pins its grants to the code hash, so every rebuild
    invalidates Microphone, Accessibility and Screen Recording and they have to
    be granted again. A Developer ID signature keeps a stable designated
    requirement and does not have this problem.
NOTE
fi
