#!/usr/bin/env bash
# Packages one built devlog-index binary as a release archive.
#
#   scripts/package-release.sh <version> <target> [prefix]
#
#   version  the release tag, e.g. v1.2.3 (used in the archive name only)
#   target   macos-arm64 | linux-x64 | linux-arm64 | windows-x64
#   prefix   the `zig build --prefix` dir holding bin/devlog-index[.exe] (default: zig-out)
#
# Writes $OUT_DIR/devlog-index-<version>-<target>.tar.gz (OUT_DIR defaults to dist)
# containing devlog-index and LICENSE at the top level, and prints its path. The
# windows-x64 target is a .zip holding devlog-index.exe (built as bin/devlog-index.exe)
# and LICENSE.
set -euo pipefail

usage() {
    echo "usage: $0 <version> <target> [prefix]" >&2
    echo "targets: macos-arm64 linux-x64 linux-arm64 windows-x64" >&2
    exit 2
}

[ $# -ge 2 ] && [ $# -le 3 ] || usage
version=$1
target=$2
prefix=${3:-zig-out}

case "$target" in
macos-arm64 | linux-x64 | linux-arm64 | windows-x64) ;;
*) echo "error: unknown target '$target'" >&2; usage ;;
esac

case "$version" in
"" | */* | *[[:space:]]*) echo "error: invalid version '$version'" >&2; usage ;;
esac

root=$(cd "$(dirname "$0")/.." && pwd)
if [ "$target" = windows-x64 ]; then exe=devlog-index.exe; ext=zip; else exe=devlog-index; ext=tar.gz; fi
bin="$prefix/bin/$exe"
[ -f "$bin" ] || { echo "error: no binary at $bin" >&2; exit 1; }
[ -f "$root/LICENSE" ] || { echo "error: no LICENSE at $root" >&2; exit 1; }

out_dir=${OUT_DIR:-dist}
mkdir -p "$out_dir"
archive="$(cd "$out_dir" && pwd)/devlog-index-$version-$target.$ext"

stage="$out_dir/.stage-$target.$$"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage"
install -m 0755 "$bin" "$stage/$exe"
install -m 0644 "$root/LICENSE" "$stage/LICENSE"

if [ "$ext" = zip ]; then
    # -X leaves out extra file attributes (owner, timestamps beyond the basics).
    rm -f "$archive" # zip adds to an existing archive
    (cd "$stage" && zip -X -q "$archive" "$exe" LICENSE)
    echo "$archive"
    exit 0
fi

# Don't record the builder's account in the archive. bsdtar and GNU tar spell this differently.
if tar --version 2>/dev/null | grep -q bsdtar; then
    owner=(--uid 0 --gid 0 --uname root --gname root)
else
    owner=(--owner=0 --group=0 --numeric-owner)
fi
tar "${owner[@]}" -czf "$archive" -C "$stage" devlog-index LICENSE
echo "$archive"
