#!/bin/bash
# Submits a signed app to Apple's notary service and staples the ticket.
#
# Requires APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD (an app-specific
# password). The notary service dominates the wall clock; a full pipeline
# usually lands in 10 to 15 minutes.
#
# Usage: scripts/notarize.sh <path-to-app>
set -euo pipefail
APP="${1:?usage: notarize.sh <path-to-app>}"

: "${APPLE_ID:?APPLE_ID is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is required}"

ARCHIVE="$(mktemp -d)/notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

echo "==> submitting to the notary service"
# The password is passed by reference: a command line is visible to any process
# on the machine, and the submission holds it for the whole wait.
xcrun notarytool submit "$ARCHIVE" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "@env:APPLE_APP_PASSWORD" \
    --wait

echo "==> stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"
