#!/bin/bash
# Source this before any `swift build` / `swift run` invocation.
#
# It repairs two Command Line Tools defects. On a healthy toolchain both checks
# pass and this script exports nothing.
#
# 1. Manifest linking. Some CLT installs ship a PackageDescription.swiftmodule
#    whose `.private.swiftinterface` predates the shipped
#    libPackageDescription.dylib. The compiler prefers the private interface,
#    resolves the old `Package.init` overload, and every manifest fails to link:
#
#      Undefined symbols: PackageDescription.Package.__allocating_init(...)
#
#    The fix is to compile manifests against a copy of the module directory with
#    the stale private interface removed. SwiftPM reads that directory from
#    SWIFTPM_CUSTOM_LIBS_DIR, and it needs both ManifestAPI and PluginAPI: the
#    FluidAudio dependency uses build plugins, and a shim holding only
#    ManifestAPI leaves the plugin manifests failing the same way.
#
# 2. C++ headers. The same installs ship a stub `usr/include/c++/v1` holding
#    around a dozen headers, which shadows the SDK's real 192-header libc++ and
#    breaks every C-family target. FluidAudio has two, so the SDK include path
#    has to be put back in front. The flags land in the MEETTAPE_SWIFT_FLAGS
#    array, which every caller of `swift build` in scripts/ passes through.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- 2. C++ header shadowing -------------------------------------------------
MEETTAPE_SWIFT_FLAGS=()
SDK_CXX="$(xcrun --show-sdk-path 2>/dev/null)/usr/include/c++/v1"
CLT_CXX="/Library/Developer/CommandLineTools/usr/include/c++/v1"
if [ -d "$CLT_CXX" ] && [ -d "$SDK_CXX" ]; then
    clt_count=$(ls -1 "$CLT_CXX" 2>/dev/null | wc -l | tr -d ' ')
    sdk_count=$(ls -1 "$SDK_CXX" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$clt_count" -lt "$sdk_count" ]; then
        MEETTAPE_SWIFT_FLAGS=(-Xcxx -I"$SDK_CXX")
    fi
fi

# --- 1. Manifest linking -----------------------------------------------------
if swift package --package-path "$REPO_ROOT" dump-package >/dev/null 2>&1; then
    return 0 2>/dev/null || exit 0
fi

TOOLCHAIN_PM_DIR="$(dirname "$(xcrun --find swift)")/../lib/swift/pm"
SHIM_DIR="$REPO_ROOT/.build/spm-libs"

for api in ManifestAPI PluginAPI; do
    source_api="$TOOLCHAIN_PM_DIR/$api"
    if [ ! -d "$source_api" ]; then
        echo "spm-env: manifest load failed and $source_api is missing" >&2
        return 1 2>/dev/null || exit 1
    fi
    if [ ! -d "$SHIM_DIR/$api" ]; then
        mkdir -p "$SHIM_DIR"
        cp -R "$source_api" "$SHIM_DIR/$api"
        chmod -R u+w "$SHIM_DIR/$api"
        find "$SHIM_DIR/$api" -name '*.private.swiftinterface' -delete
    fi
done

export SWIFTPM_CUSTOM_LIBS_DIR="$SHIM_DIR"

if ! swift package --package-path "$REPO_ROOT" dump-package >/dev/null 2>&1; then
    echo "spm-env: manifest still fails to load with the shim in place" >&2
    return 1 2>/dev/null || exit 1
fi
