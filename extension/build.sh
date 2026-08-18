#!/bin/bash
# Assembles loadable extension directories for each browser.
#
# Firefox uses MV2 with a module background page; Chrome needs MV3 with a service
# worker. The observation code is identical, so only the manifest differs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dist"
rm -rf "$DIST"
for browser in firefox chrome; do
    mkdir -p "$DIST/$browser/shared"
    cp "$ROOT/shared/"*.js "$DIST/$browser/shared/"
    cp "$ROOT/$browser/manifest.json" "$DIST/$browser/manifest.json"
    echo "built $DIST/$browser"
done
