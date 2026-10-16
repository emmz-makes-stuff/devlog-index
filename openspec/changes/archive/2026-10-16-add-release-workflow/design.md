# Design

## Context

- `build.zig` takes `-Dtarget`/`-Doptimize` through the standard options and builds sqlite and sqlite-vec from
  vendored C, plus llama.cpp through the pinned `daemonicai/llama.cpp.zig` fork, CPU backend only. Nothing
  links system libraries except libc, so cross-compiling is plausible.
- The `Makefile` points `ZIG_LIBC` at the macOS SDK 26 because Zig 0.16.0's libc++ can't build against SDK 27.
  That is a macOS-host quirk; a Linux runner cross-compiling to macOS uses Zig's bundled libc headers
  for `aarch64-macos` and does not hit it. Whether the llama.cpp fork builds that way is **unproven**.
- Tests are hermetic; model-dependent ones skip without `DEVLOG_INDEX_TEST_MODEL`.

## Goals / Non-Goals

**Goals:**
- One ubuntu job builds all three targets; builds are reproducible from the tag.
- CI mirrors `make format` and `make test` without the macOS-only libc setup.

**Non-Goals:**
- Code signing or notarization (macOS users may need to clear quarantine; documented in README).
- Windows. The spike showed it fails to compile (`Quiet` in `src/model.zig` uses POSIX `open`/`dup`/`dup2`
  through `std.c`) and `src/main.zig` assumes `HOME`. A native Windows runner would hit the same errors,
  so it needs source porting, which is a future change.
- Other targets (macos-x64, windows-arm64, musl), installers, Homebrew/winget packaging.
- Running the cross-compiled binaries in CI (only the host-native linux-x64 binary is smoke-tested).

## Decisions

- **Spike first.** Section 1 cross-compiles the targets before the real workflows are written, as a
  throwaway GitHub Actions run on ubuntu-24.04 (the production host). A local amd64 OrbStack machine was
  tried first but runs under Rosetta, which crashes Zig's `translate-c` (`bss_size overflow`). If a target
  can't be cross-compiled, stop and ask Emmz; the fallback is a native runner for that target only
  (macos-14, ubuntu-24.04-arm) in a build matrix.
- **Zig cross-compile on one runner**, as chosen, over a native matrix: one toolchain install, no
  per-OS quirks, fast. Cost: foreign binaries are not executed in CI.
- **Pinned Zig 0.16.0** via `mlugg/setup-zig` (or the ziglang.org tarball with checksum), matching
  `minimum_zig_version`. Third-party actions are pinned to a commit SHA.
- **Release job split:** a `build` step produces archives and `SHA256SUMS`, uploaded as workflow artifacts on
  every trigger; a separate `publish` job runs only on tag refs, needs `build`, has `contents: write`, and
  attaches the files with `gh release create`. Dispatch therefore can't publish, and the build job runs
  with read-only permissions.
- **Version = tag** (`v1.2.3`), used for archive names only. `build.zig.zon`'s `.version` stays as is;
  keeping them in sync is out of scope.
- **Packaging via a script** (`scripts/package-release.sh`) so it can be run locally and checked by the
  smoke test, rather than inlined YAML.
- **CI** runs `zig fmt --check src build.zig` and `zig build test --summary all` on ubuntu. It doesn't go
  through `make` because the `Makefile`'s libc step is macOS-specific.
- **Smoke test:** run the linux-x64 binary with `--help` (or equivalent) before publishing.

## Risks / Trade-offs

- [Cross-compile fails for macOS (llama.cpp C++ / libc++)] → the spike finds it before any real
  workflow is written; fallback is a native runner for that target.
- [Finding, not a risk: Windows] The spike's `x86_64-windows` build compiled sqlite, sqlite-vec and
  llama.cpp, then failed on two errors in our own source (`Quiet`). Deferred; see Non-Goals.
- [Unexecuted foreign binaries could be broken] → only link-level checks are possible; accept and note in README.
- [Unsigned macOS binary is quarantined by Gatekeeper] → document `xattr -d com.apple.quarantine`.
- [Fork dependency fetched from GitHub at build time] → already true of every build; Zig's package hash pins it.
