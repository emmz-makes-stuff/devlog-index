#!/usr/bin/env bash
# Tests package-release.sh and checksums.sh with a fake binary (no Zig build needed).
# Works with both bsdtar (macOS) and GNU tar (CI).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work="${TMPDIR:-/tmp}/devlog-index-release-test.$$"
mkdir -p "$work/prefix/bin"
trap 'rm -rf "$work"' EXIT

printf '#!/bin/sh\necho fake\n' > "$work/prefix/bin/devlog-index"
chmod 0644 "$work/prefix/bin/devlog-index" # the packager must set the exec bit itself

failures=0
check() { # check <description> <command...>
    local what=$1
    shift
    if "$@" >/dev/null 2>&1; then echo "ok   $what"; else echo "FAIL $what"; failures=$((failures + 1)); fi
}
check_not() { # check_not <description> <command...>  (the command must fail)
    local what=$1
    shift
    if "$@" >/dev/null 2>&1; then echo "FAIL $what"; failures=$((failures + 1)); else echo "ok   $what"; fi
}

export OUT_DIR="$work/dist"
targets="macos-arm64 linux-x64 linux-arm64"

for t in $targets; do
    check "package $t" "$here/package-release.sh" v1.2.3 "$t" "$work/prefix"
    a="$OUT_DIR/devlog-index-v1.2.3-$t.tar.gz"
    check "$t archive is named for version and target" test -f "$a"
    listing=$(tar -tzf "$a" 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ')
    check "$t archive holds exactly devlog-index and LICENSE" test "$listing" = "LICENSE devlog-index "
    mkdir -p "$work/x-$t" && tar -xzf "$a" -C "$work/x-$t"
    # Positive check: every entry is owned by root (bsdtar prints "root  wheel"/"0 0", GNU tar "root/root").
    verbose=$(tar -tzvf "$a" 2>/dev/null)
    check "$t archive lists two entries" test "$(printf '%s\n' "$verbose" | grep -c .)" = 2
    check "$t archive entries are owned by root" \
        test "$(printf '%s\n' "$verbose" | grep -Ec '^[-rwx]{10} +(0|root)[ /]+(0|root|wheel)[ ]')" = 2
    check "$t binary is executable" test -x "$work/x-$t/devlog-index"
    check "$t LICENSE matches the repo's" cmp -s "$work/x-$t/LICENSE" "$here/../LICENSE"
done

check_not "unknown target is rejected" "$here/package-release.sh" v1.2.3 windows-x64 "$work/prefix"
check_not "empty version is rejected" "$here/package-release.sh" "" linux-x64 "$work/prefix"
check_not "version with a slash is rejected" "$here/package-release.sh" v1/2 linux-x64 "$work/prefix"
check_not "missing binary is rejected" "$here/package-release.sh" v1.2.3 linux-x64 "$work/nowhere"
check_not "no staging dir is left behind" sh -c "ls -a '$OUT_DIR' | grep -q '^\.stage-'"

check "checksums are written" "$here/checksums.sh" "$OUT_DIR"
check "SHA256SUMS lists every archive" test "$(wc -l < "$OUT_DIR/SHA256SUMS" | tr -d ' ')" = 3
if command -v sha256sum >/dev/null 2>&1; then verify="sha256sum -c"; else verify="shasum -a 256 -c"; fi
check "SHA256SUMS verifies from the archive directory" sh -c "cd '$OUT_DIR' && $verify SHA256SUMS"
echo tamper >> "$OUT_DIR/devlog-index-v1.2.3-linux-x64.tar.gz"
check_not "a tampered archive fails verification" sh -c "cd '$OUT_DIR' && $verify SHA256SUMS"
check_not "checksums.sh rejects a dir with no archives" "$here/checksums.sh" "$work/prefix"

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
