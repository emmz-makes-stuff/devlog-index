# Tasks

## 1. Windows build feasibility

- [ ] 1.1 Run `zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows` on the Mac through `make`'s libc setup (or unset `ZIG_LIBC` if it interferes) and verify it either links `devlog-index.exe` or record the exact failure in a devlog note
- [ ] 1.2 If it fails inside `daemonicai/llama.cpp.zig`, SQLite or sqlite-vec, stop and ask Emmz before changing the fork pin or vendored C (per CLAUDE.md "Stop and ask"); verify by a `stopped-…` devlog note stating the error and the question
- [ ] 1.3 Verify `zig build test -Dtarget=x86_64-windows` at least compiles the test binary (it can't run on macOS) and note the result in the devlog

## 2. Platform code

- [ ] 2.1 Add a `homeDir` helper (`HOME`, else `USERPROFILE`, else a fatal naming both) and replace the five `HOME` lookups in `src/main.zig`; verify with unit tests for the three cases and `make test` green
- [ ] 2.2 Make `model.Quiet` redirect stderr through the CRT on Windows (`_open("NUL")`, `_dup`, `_dup2`), keeping the leave-stderr-alone fallback; update the doc comments in `src/model.zig` and `src/embed.zig`; verify the file compiles for both `x86_64-windows` and the host, and `make test` stays green
- [ ] 2.3 Record workspace-relative passage paths with `/` separators and join with the native separator only to open files (`src/sources.zig` and its callers); verify with a test that feeds a `\`-separated relative path and expects `/` in the stored and printed path, and that existing path tests still pass
- [ ] 2.4 Check `sources.zig`'s broken-link handling covers the errors Windows returns for unreadable or unresolvable links; make the symlink-creating tests skip with an explicit message when link creation is refused; verify with `make test` and a read of the skip output
- [ ] 2.5 Set both `HOME` and `USERPROFILE` in `src/cli_test.zig`'s child environment; verify the CLI tests still pass
- [ ] 2.6 `make gates` green; self-review against `platform-support` scenarios (one line per scenario saying which test or CI job covers it)

## 3. Packaging scripts

- [ ] 3.1 Teach `scripts/package-release.sh` the `windows-x64` target: archive `devlog-index.exe` + `LICENSE` as `devlog-index-<version>-windows-x64.zip`; update its usage text; verify with `scripts/test-release-scripts.sh`
- [ ] 3.2 Make `scripts/checksums.sh` list `*.zip` as well as `*.tar.gz`; verify `SHA256SUMS` covers four archives in the script test
- [ ] 3.3 Extend `scripts/test-release-scripts.sh` for the zip: name, exact contents, exe bit not required, unknown target still rejected; verify it prints no `FAIL` on macOS and Linux
- [ ] 3.4 `make gates` green

## 4. Workflows

- [ ] 4.1 Add a `windows-latest` job to `.github/workflows/ci.yml` that installs Zig 0.16.0 (pinned download and SHA-256 as the Linux job does) and runs `zig build test --summary all`; verify on a pushed branch that it runs and is green
- [ ] 4.2 Add the same Windows test job to `release.yml`, make publishing depend on it, and add `windows-x64:x86_64-windows` to the cross-build loop; verify with a `workflow_dispatch` dry run that four archives and `SHA256SUMS` are uploaded as workflow artifacts and no Release is created
- [ ] 4.3 Add a smoke test that runs `devlog-index.exe --help` on the Windows runner against the real built binary and checks `Usage: devlog-index`; verify in the dry run
- [ ] 4.4 `make validate` green and self-review the workflows against the `release-distribution` delta, including the "Release requires passing checks" and "Publishing only from a tag push" requirements

## 5. Installer and docs

- [ ] 5.1 Write `install.ps1` (`-Version`, default latest; download zip + `SHA256SUMS`; `Get-FileHash` compare; install to `$env:LOCALAPPDATA\Programs\devlog-index`; `PATH` hint); verify it runs in PowerShell against the dry-run or a real release and installs a working `devlog-index.exe`
- [ ] 5.2 Verify the checksum-mismatch path: point it at a tampered archive and confirm it installs nothing and exits non-zero naming both hashes
- [ ] 5.3 Update `README.md` (Windows install, `USERPROFILE` model cache location, symlink caveat) and verify the commands in it run as written on Windows

## 6. Human verification on Windows

- [ ] 6.1 STOP for Emmz: on a Windows machine, install via `install.ps1`, run `devlog-index update` and `query` on a real workspace and judge whether the results look right; I provide a copy-pasteable recipe and write the result in the devlog

## Workflow follow-up

- Run the whole-change review (and offer `code-review`) per CLAUDE.md before archiving.
- Archive the change with `/opsx:archive` after Emmz agrees; it syncs `platform-support` and the `release-distribution` delta into the main specs.
