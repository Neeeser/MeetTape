#!/bin/bash
# Downloads the recordings the benchmark suites score against.
#
# The audio is never committed: CI fails the build on any audio file in the
# tree, and both corpora are published under CC BY 4.0 from Edinburgh. Each file
# is verified against the SHA-256 pinned in Benchmarks/manifest.json, so a
# mirror serving a re-encoded copy is caught rather than silently measured.
#
# Usage: scripts/fetch-bench-audio.sh [suite] [--audio-dir DIR]
#        scripts/fetch-bench-audio.sh --annotations [ami|icsi]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/Benchmarks/manifest.json"
AUDIO_DIR="$HOME/Library/Caches/meettape-bench"
SUITE="ami-core"
ANNOTATIONS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --audio-dir) AUDIO_DIR="$2"; shift 2 ;;
        --annotations)
            ANNOTATIONS="ami"
            if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then ANNOTATIONS="$2"; shift; fi
            shift ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) SUITE="$1"; shift ;;
    esac
done

mkdir -p "$AUDIO_DIR"

# One line per file: url, sha256, local name. The manifest holds a mirror
# template for AMI and a full URL for anything published elsewhere, and the
# local name is always the last path component, which is what the ground truth
# names as its source.
read_manifest() {
    python3 -c '
import json, sys, posixpath
manifest = json.load(open(sys.argv[1]))
what = sys.argv[2]
if what.startswith("annotations:"):
    corpus = what.split(":", 1)[1]
    archives = manifest["annotations"]
    if corpus not in archives:
        sys.exit("no annotations for %s" % corpus)
    url = archives[corpus]["url"]
    print("%s %s %s" % (url, archives[corpus]["sha256"], posixpath.basename(url)))
    sys.exit(0)
if what not in manifest["suites"]:
    sys.exit("no suite named %s" % what)
for meeting in manifest["suites"][what]:
    url = manifest.get("audioURL", {}).get(meeting)
    if url is None:
        url = manifest["mirror"].replace("{meeting}", meeting)
    print("%s %s %s" % (url, manifest["audio"][meeting], posixpath.basename(url)))
' "$MANIFEST" "$1"
}

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

# Read into an array the long way: macOS ships bash 3.2, which has no mapfile.
LINES=()
if [ -n "$ANNOTATIONS" ]; then
    while IFS= read -r line; do LINES+=("$line"); done < <(read_manifest "annotations:$ANNOTATIONS")
else
    while IFS= read -r line; do LINES+=("$line"); done < <(read_manifest "$SUITE")
fi

# A bad suite or corpus name leaves the array empty, and bash 3.2 under `set -u`
# expands an empty array as an unbound variable rather than as nothing.
if [ ${#LINES[@]} -eq 0 ]; then
    echo "nothing to fetch: the manifest named no files" >&2
    exit 1
fi

for line in "${LINES[@]}"; do
    url="$(echo "$line" | cut -d' ' -f1)"
    sha="$(echo "$line" | cut -d' ' -f2)"
    name="$(echo "$line" | cut -d' ' -f3)"
    fetch "$url" "$AUDIO_DIR/$name" "$sha"
done

if [ -n "$ANNOTATIONS" ]; then
    echo "$ANNOTATIONS annotations in $AUDIO_DIR"
else
    echo "suite $SUITE ready in $AUDIO_DIR"
fi
