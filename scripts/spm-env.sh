#!/bin/bash
# Source this before any `swift build` / `swift run` invocation.
#
# Some Command Line Tools installs ship a PackageDescription.swiftmodule whose
# `.private.swiftinterface` predates the shipped libPackageDescription.dylib. The
# compiler prefers the private interface, resolves the old `Package.init`
# overload, and every manifest then fails to link:
#
#   Undefined symbols: PackageDescription.Package.__allocating_init(... swiftLanguageVersions: ...)
#
# The fix is to compile manifests against a copy of the module directory with the
# stale private interface removed. SwiftPM reads that directory from
# SWIFTPM_CUSTOM_LIBS_DIR. On a healthy toolchain this script exports nothing.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if swift package --package-path "$REPO_ROOT" dump-package >/dev/null 2>&1; then
    return 0 2>/dev/null || exit 0
fi

TOOLCHAIN_PM_DIR="$(dirname "$(xcrun --find swift)")/../lib/swift/pm"
SOURCE_MANIFEST_API="$TOOLCHAIN_PM_DIR/ManifestAPI"

if [ ! -d "$SOURCE_MANIFEST_API" ]; then
    echo "spm-env: manifest load failed and $SOURCE_MANIFEST_API is missing" >&2
    return 1 2>/dev/null || exit 1
fi

SHIM_DIR="$REPO_ROOT/.build/spm-libs"
if [ ! -d "$SHIM_DIR/ManifestAPI" ]; then
    mkdir -p "$SHIM_DIR"
    cp -R "$SOURCE_MANIFEST_API" "$SHIM_DIR/ManifestAPI"
    chmod -R u+w "$SHIM_DIR"
    rm -f "$SHIM_DIR"/ManifestAPI/PackageDescription.swiftmodule/*.private.swiftinterface
fi

export SWIFTPM_CUSTOM_LIBS_DIR="$SHIM_DIR"

if ! swift package --package-path "$REPO_ROOT" dump-package >/dev/null 2>&1; then
    echo "spm-env: manifest still fails to load with the shim in place" >&2
    return 1 2>/dev/null || exit 1
fi
