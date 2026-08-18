#!/bin/bash
# Filters swift build/test output down to diagnostics and harness output.
sed 's/\x1b\[[0-9;]*m//g' \
  | sed '/^Failed frontend command:/,/^error: Build failed$/d' \
  | grep -vE "^\[[0-9]+/[0-9]+\]|^Building for|^Build complete|ld: warning: search path|^Compiling |^\s*$" \
  | grep -vE "^\s+[0-9]+ \|"
