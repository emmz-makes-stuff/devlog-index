# Design

## Context

See proposal.md for motivation. Observed today:

- `src/main.zig` reads `HOME` at five call sites (`update`, `status`, `query`, `eval`, model download) to
  build `<home>/.devlog-index/models/...` through `model_url.cachePathZ`, which already uses
  `std.fs.path.joinZ`.
- `src/model.zig` `Quiet` silences llama.cpp's `fprintf(stderr)` with `std.c.open("/dev/null")`, `dup` and
  `dup2` on `std.posix.STDERR_FILENO`; `src/embed.zig` reuses it. Both are documented POSIX-only with a
  graceful fallback.
- `src/sources.zig` follows symlinks and tests create them with `symLink`; creating one on Windows needs
  Developer Mode or elevation.
- `build.zig` builds vendored SQLite and sqlite-vec from C and takes llama.cpp from the pinned
  `daemonicai/llama.cpp.zig` fork, CPU backend, `link_libc = true`. The Makefile's SDK 26 libc workaround
  is macOS-only and CI already builds on Linux without it.
- Releases are `.tar.gz` built by `scripts/package-release.sh` on one Linux runner by cross-compiling; the
  only runnable target is checked with a smoke test. `install.sh` builds from source, it does not download.
- `src/cli_test.zig` spawns the built binary with an environment containing only `HOME`.

## Goals / Non-Goals

**Goals:**
- A `windows-x64` binary that passes the same test suite natively, gating both CI and release.
- No behaviour difference for macOS/Linux users.

**Non-Goals:**
- `aarch64-windows`, GPU backends, Windows dev gates (`Makefile`), an MSI/winget/scoop package.
- Following symlinks on Windows beyond what `std.fs` already offers.

## Decisions

**D1. Home directory: `HOME`, else `USERPROFILE`, in one helper.** Replace the five repeated
`init.environ_map.get("HOME") orelse fatal(...)` with one `homeDir(environ_map)` that tries both and fails
naming both. Alternatives: `std.fs.getAppDataDir` (puts the model in `AppData`, breaking the documented
`~/.devlog-index/` layout and splitting caches by platform); a Windows-only `#if` (duplicates the call sites).
Preferring `HOME` keeps Git Bash and WSL-style setups on the same cache as before.

**D2. Quiet stderr on Windows via the CRT, not Win32 handles.** llama.cpp writes through the C runtime's
`stderr`, and the binary links libc, so the CRT's `_dup`/`_dup2`/`_open("NUL")` redirect exactly the stream
that needs silencing. `Quiet` branches on `builtin.os.tag == .windows` for the three calls and keeps the
same "leave stderr alone on any failure" rule. Alternative: `SetStdHandle(STD_ERROR_HANDLE)` — does not
affect the CRT's already-bound fd 2. Alternative: pass llama's log callback only — already done and does not
cover direct `fprintf`.

**D3. Symlinks: keep following them; treat any failure to resolve as a broken link.** `sources.zig` already
skips and reports links that error. On Windows, tests that need to create links skip when creation returns
`AccessDenied`/`PermissionDenied`, and the CI runner (Developer Mode off, but runners are admin) is expected
to be able to create them; a test that cannot create a link must say "skipped", never pass silently. No
production behaviour changes beyond verifying that error set covers Windows' errors (e.g. `FileNotFound`,
`AccessDenied`, reparse-point errors).

**D4. Reported paths use `/`.** Passage paths are workspace-relative strings stored in the index and printed
in `--json`. They are built with `std.fs.path.join`, which would use `\` on Windows, making an index and
output differ by platform. Normalise at the point a relative path is recorded (the `rel` in `sources.zig`)
and join to disk paths with the native separator only when opening files. Alternative: leave native
separators — rejected, it breaks the agent query skill's output expectations and any golden set.

**D5. Windows zip, Linux-built.** Keep one cross-compiling Linux `build` job and add `x86_64-windows` to its
loop; package with a new `.zip` branch in `package-release.sh` using `zip` (installed on `ubuntu-24.04`;
`-X` and fixed timestamps are not required because zips carry no owner). A separate `windows-latest`
`test` job in both workflows runs `zig build test --summary all` natively and gates publishing. Alternative:
build the release binary on the Windows runner — rejected, it would make the release depend on two
toolchains and break the "same flags everywhere" property. `checksums.sh` globs `*.tar.gz` and `*.zip`.

**D6. `install.ps1` downloads, `install.sh` is unchanged.** `install.ps1` takes optional `-Version`,
resolves `latest` through the GitHub releases API, downloads the zip and `SHA256SUMS`, compares with
`Get-FileHash`, extracts with `Expand-Archive`, and installs to `$env:LOCALAPPDATA\Programs\devlog-index`.
It prints a `PATH` hint rather than editing the registry (matches `install.sh`'s behaviour). Alternative:
edit the user `PATH` — rejected, silent environment changes surprised users before; the hint is enough.

**D7. Tests that spawn the binary pass both `HOME` and `USERPROFILE`.** `cli_test.zig`'s environment gets
both pointed at the same empty temp dir, so the CLI tests exercise the Windows lookup path too.

## Risks / Trade-offs

- [The llama.cpp.zig fork or SQLite/sqlite-vec doesn't compile or link for `x86_64-windows`] → this is the
  gating unknown, so section 1 only cross-compiles and records the result before any porting. If the fork
  needs changes they land upstream in `daemonicai/llama.cpp.zig`, the pin in `build.zig.zon` moves, and
  that is a stop-and-ask (new dependency version).
- [CRT redirection fails silently, so Windows users see llama diagnostics] → the spec allows this; the
  failure mode is noise, not breakage. A native CI test asserts the quiet path works.
- [Symlink tests cannot run on the runner] → tests report skipped explicitly; Windows symlink behaviour is
  then unverified, recorded in the devlog.
- [Model download over HTTPS on Windows] → whatever `update.zig` uses for the download must work with
  Windows' TLS roots; the end-to-end check in section 5 downloads the real model once.
- [Long paths over 260 chars in deep workspaces] → not addressed; Zig's Windows file APIs use the `\\?\`
  prefix, so expected to work, but unverified.

## Migration Plan

Additive. No index schema change: an index built on macOS is not meant to be shared with Windows (paths in
it are workspace-relative with `/`, but absolute workspace paths are not stored). Rollback is not shipping
the Windows archive; nothing for existing platforms changes.

## Open Questions

- Does Emmz have a Windows machine for the one-off human check (indexing the real `nova` workspace)? Not
  needed for the specs or task list; asked at that task.
