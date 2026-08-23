#!/bin/bash
# Downloads the AMI recordings the benchmark suite scores against.
#
# The audio is never committed: CI fails the build on any audio file in the
# tree, and the AMI corpus is published under CC BY 4.0 from Edinburgh. Each
# file is verified against the SHA-256 pinned in Benchmarks/manifest.json, so a
# mirror serving a re-encoded copy is caught rather than silently measured.
#
# Usage: scripts/fetch-bench-audio.sh [suite] [--audio-dir DIR]
#        scripts/fetch-bench-audio.sh --annotations   # the manual annotations zip
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/Benchmarks/manifest.json"
AUDIO_DIR="$HOME/Library/Caches/meettape-bench"
SUITE="ami-core"
WANT_ANNOTATIONS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --audio-dir) AUDIO_DIR="$2"; shift 2 ;;
        --annotations) WANT_ANNOTATIONS=1; shift ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) SUITE="$1"; shift ;;
    esac
done

mkdir -p "$AUDIO_DIR"

read_manifest() {
    python3 -c '
import json, sys
manifest = json.load(open(sys.argv[1]))
print(manifest["mirror"])
print(manifest["annotations"]["url"])
print(manifest["annotations"]["sha256"])
suite = sys.argv[2]
if suite not in manifest["suites"]:
    sys.exit("no suite named %s" % suite)
for meeting in manifest["suites"][suite]:
    print("%s %s" % (meeting, manifest["audio"][meeting]))
' "$MANIFEST" "$SUITE"
}

# Read into an array the long way: macOS ships bash 3.2, which has no mapfile.
LINES=()
while IFS= read -r line; do LINES+=("$line"); done < <(read_manifest)
MIRROR="${LINES[0]}"
ANNOTATIONS_URL="${LINES[1]}"
ANNOTATIONS_SHA="${LINES[2]}"

verify() {
    local path="$1" expected="$2"
    local actual
    actual="$(shasum -a 256 "$path" | cut -d' ' -f1)"
    if [ "$actual" != "$expected" ]; then
        echo "checksum mismatch for $path" >&2
        echo "  expected $expected" >&2
        echo "  got      $actual" >&2
        return 1
    fi
}

fetch() {
    local url="$1" path="$2" expected="$3"
    if [ -f "$path" ] && verify "$path" "$expected" 2>/dev/null; then
        echo "have    $(basename "$path")"
        return 0
    fi
    echo "fetch   $(basename "$path")"
    curl -fL --retry 3 --progress-bar -o "$path.partial" "$url"
    verify "$path.partial" "$expected" || { rm -f "$path.partial"; return 1; }
    mv "$path.partial" "$path"
}

if [ "$WANT_ANNOTATIONS" = 1 ]; then
    fetch "$ANNOTATIONS_URL" "$AUDIO_DIR/ami_public_manual_1.6.2.zip" "$ANNOTATIONS_SHA"
    echo "annotations in $AUDIO_DIR"
    exit 0
fi

for line in "${LINES[@]:3}"; do
    meeting="${line%% *}"
    sha="${line##* }"
    url="${MIRROR//\{meeting\}/$meeting}"
    fetch "$url" "$AUDIO_DIR/$meeting.Mix-Headset.wav" "$sha"
done

echo "suite $SUITE ready in $AUDIO_DIR"
