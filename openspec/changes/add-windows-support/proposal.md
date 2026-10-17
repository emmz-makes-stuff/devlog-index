# Proposal

## Why

`devlog-index` runs on macOS arm64 and Linux only. Teammates on Windows can't use it to query a workspace's
OpenSpec specs and devlog notes. The code is mostly portable Zig, but a few places assume POSIX (`$HOME`,
`/dev/null` stderr silencing, symlinks), and nothing builds, tests or ships a Windows binary.

## What Changes

- Resolve the user's home directory on Windows (`USERPROFILE`) as well as POSIX (`HOME`), so the model cache
  at `<home>/.devlog-index/models/` works everywhere.
- Silence llama.cpp's stderr chatter on Windows (today a POSIX-only `dup`/`dup2` of `/dev/null`), keeping the
  graceful fallback to leaving stderr intact.
- Make symlink handling degrade cleanly on Windows, where creating symlinks needs privilege and the index
  walks real files by default.
- Add `x86_64-windows` to the release build, packaged as `devlog-index-<version>-windows-x64.zip`
  (`devlog-index.exe` + `LICENSE`) and listed in `SHA256SUMS`.
- Add a `windows-latest` job to CI and the release workflow that builds and runs the full test suite natively.
- Add `install.ps1`, which downloads the latest release zip, verifies it against `SHA256SUMS`, and installs
  `devlog-index.exe` to a per-user directory on `PATH`.
- Dev gates (`Makefile`, `make gates`) stay macOS/Linux. **Not** in scope: `aarch64-windows`, building from
  source on Windows by hand beyond what CI does, and GPU backends.

## Capabilities

### New Capabilities
- `platform-support`: the binary behaves the same on Windows as on macOS/Linux: home-directory and model-cache
  location, quiet model loading, paths with either separator, and symlinks that can't be created or followed.

### Modified Capabilities
- `release-distribution`: a fourth release target (windows-x64) packaged as a `.zip`, Windows CI/release
  jobs that run tests natively, and a PowerShell installer.

## Impact

- Code: `src/main.zig` (home lookup, five call sites), `src/model.zig` and `src/embed.zig` (stderr
  silencing), `src/sources.zig` (symlink handling and its tests), `src/cli_test.zig` (spawns the binary with
  `HOME` only), `src/embed.zig` thread count (already generic).
- Build: `build.zig` for `x86_64-windows` (sqlite, sqlite-vec and the pinned `daemonicai/llama.cpp.zig`
  fork must all compile and link for it; this is the biggest unknown, see design).
- CI: `.github/workflows/ci.yml`, `release.yml`; `scripts/package-release.sh` and `scripts/checksums.sh`
  gain a zip path; new `install.ps1`; README install section; `docs/dependencies.md` unchanged (Makefile
  gates remain mac/Linux).
