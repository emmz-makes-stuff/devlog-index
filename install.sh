#!/usr/bin/env bash
# Builds devlog-index with ReleaseFast and copies it to ~/.local/bin (or $PREFIX/bin).
# The build goes through `make release`, which points Zig at the SDK 26 headers on macOS.
set -euo pipefail

cd "$(dirname "$0")"
make release

bin_dir="${PREFIX:-$HOME/.local}/bin"
mkdir -p "$bin_dir"
install -m 0755 zig-out/bin/devlog-index "$bin_dir/devlog-index"
echo "installed $bin_dir/devlog-index"

case ":$PATH:" in
*":$bin_dir:"*) ;;
*) echo "note: $bin_dir is not on PATH; add it to run devlog-index by name" ;;
esac
