#!/bin/bash
# Packages dist/Pipit.app as a zip and a dmg, with checksums.
#
# Usage: scripts/package.sh <version>
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(cat "$REPO_ROOT/VERSION")}"
APP="$REPO_ROOT/dist/Pipit.app"
OUT="$REPO_ROOT/dist"

test -d "$APP" || { echo "build the app first: scripts/bundle-app.sh release" >&2; exit 1; }

ZIP="$OUT/Pipit-$VERSION.zip"
DMG="$OUT/Pipit-$VERSION.dmg"
rm -f "$ZIP" "$DMG"

# ditto preserves the bundle's signature and symlinks; zip does not.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Pipit $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

( cd "$OUT" && shasum -a 256 "Pipit-$VERSION.zip" "Pipit-$VERSION.dmg" ) > "$OUT/Pipit-$VERSION.sha256"
cat "$OUT/Pipit-$VERSION.sha256"
