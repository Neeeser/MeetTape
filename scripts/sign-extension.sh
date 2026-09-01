#!/bin/bash
# Signs the Firefox extension with Mozilla's add-on service and leaves the
# signed XPI at extension/dist/pipit-sensor.xpi, where bundle-app.sh picks it up.
#
# Release Firefox installs a signed add-on permanently and refuses an unsigned
# one, so without this the only way in is about:debugging, and the add-on is
# dropped every time Firefox quits. The channel is "unlisted": Mozilla signs the
# file and hands it back rather than publishing it, because the add-on is
# useless without Pipit next to it.
#
# Credentials come from https://addons.mozilla.org/en-US/developers/addon/api/key/
# and are read from the environment, never passed on the command line, where
# they would land in the process list.
#
# Usage: AMO_JWT_ISSUER=... AMO_JWT_SECRET=... scripts/sign-extension.sh [version]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTENSION="$REPO_ROOT/extension"
SOURCE_DIR="$EXTENSION/dist/firefox"
# Outside extension/dist, which extension/build.sh wipes on every build.
ARTIFACTS="$EXTENSION/signed/artifacts"
OUTPUT="$EXTENSION/signed/pipit-sensor.xpi"

if [ -z "${AMO_JWT_ISSUER:-}" ] || [ -z "${AMO_JWT_SECRET:-}" ]; then
    echo "AMO_JWT_ISSUER and AMO_JWT_SECRET must be set" >&2
    exit 1
fi

"$EXTENSION/build.sh" >/dev/null

# AMO refuses a version it has already signed for this add-on, so a release
# stamps the built manifest with the app's version. The source manifest is left
# alone: it is what an unsigned about:debugging load reads.
if [ "$#" -ge 1 ]; then
    VERSION="$1"
    case "$VERSION" in
        *[!0-9.]*|"") echo "version must be numeric, got: $VERSION" >&2; exit 1 ;;
    esac
    VERSION="$VERSION" node -e '
        const fs = require("fs");
        const path = process.argv[1];
        const manifest = JSON.parse(fs.readFileSync(path, "utf8"));
        manifest.version = process.env.VERSION;
        fs.writeFileSync(path, JSON.stringify(manifest, null, 2) + "\n");
    ' "$SOURCE_DIR/manifest.json"
    echo "==> signing version $VERSION"
fi

rm -rf "$EXTENSION/signed"
mkdir -p "$ARTIFACTS"

# web-ext is fetched on demand rather than held as a dependency of the
# extension, which otherwise has none and needs no install to build or test.
WEB_EXT_API_KEY="$AMO_JWT_ISSUER" WEB_EXT_API_SECRET="$AMO_JWT_SECRET" \
    npx --yes web-ext@8 sign \
    --source-dir "$SOURCE_DIR" \
    --artifacts-dir "$ARTIFACTS" \
    --channel unlisted \
    --no-input

signed="$(find "$ARTIFACTS" -name '*.xpi' -maxdepth 1 | head -1)"
if [ -z "$signed" ]; then
    echo "signing reported success but produced no xpi" >&2
    exit 1
fi

mv "$signed" "$OUTPUT"
rm -rf "$ARTIFACTS"
echo "==> signed add-on at $OUTPUT"
