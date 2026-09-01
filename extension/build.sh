#!/bin/bash
# Assembles loadable extension directories for each browser.
#
# The sources are ES modules so they can be unit tested under Node, but a content
# script cannot be a module: an `import` statement makes the whole script fail to
# load and the sensor silently never runs. The build therefore strips the module
# syntax and ships plain scripts that share the content-script scope.
#
# Firefox uses MV2 with a background page; Chrome needs MV3 with a service
# worker. The observation code is identical, so only the manifest differs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dist"
rm -rf "$DIST"

for browser in firefox chrome; do
    mkdir -p "$DIST/$browser/shared"
    # `export ` prefixes and the import block are the only module syntax used.
    sed -E 's/^export (function|const|let|class)/\1/' "$ROOT/shared/provider.js" \
        > "$DIST/$browser/shared/provider.js"
    cp "$ROOT/shared/content.js" "$DIST/$browser/shared/content.js"
    cp "$ROOT/shared/background.js" "$DIST/$browser/shared/background.js"
    cp "$ROOT/$browser/manifest.json" "$DIST/$browser/manifest.json"
    # The app icon, which is what the browser shows in its add-on list and in
    # the install prompt. Without it the browser draws a generic puzzle piece.
    cp -R "$ROOT/icons" "$DIST/$browser/icons"

    for file in provider.js content.js background.js; do
        if grep -qE '^\s*(import|export)\s' "$DIST/$browser/shared/$file"; then
            echo "module syntax survived in $browser/shared/$file" >&2
            exit 1
        fi
    done
    node --check "$DIST/$browser/shared/provider.js"
    node --check "$DIST/$browser/shared/content.js"
    node --check "$DIST/$browser/shared/background.js"
    echo "built $DIST/$browser"
done
