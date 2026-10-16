#!/usr/bin/env bash
# Writes SHA256SUMS for every devlog-index-*.tar.gz in a directory.
#
#   scripts/checksums.sh <dir>
#
# Entries use bare file names, so `sha256sum -c SHA256SUMS` (or `shasum -a 256 -c`)
# works from the directory the archives were downloaded into.
set -euo pipefail

[ $# -eq 1 ] && [ -d "$1" ] || { echo "usage: $0 <dir>" >&2; exit 2; }
cd "$1"

shopt -s nullglob
archives=(devlog-index-*.tar.gz)
[ ${#archives[@]} -gt 0 ] || { echo "error: no devlog-index-*.tar.gz in $1" >&2; exit 1; }

if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${archives[@]}" > SHA256SUMS
else
    shasum -a 256 "${archives[@]}" > SHA256SUMS
fi
echo "SHA256SUMS: ${#archives[@]} archives"
