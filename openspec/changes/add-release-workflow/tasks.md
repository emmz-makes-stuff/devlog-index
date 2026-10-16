# Tasks

## 1. Cross-compile spike

- [ ] 1.1 Cross-compile `zig build -Doptimize=ReleaseFast -Dtarget=<t>` for `x86_64-windows`, `aarch64-macos`, `x86_64-linux` and `aarch64-linux` from a non-macOS environment (OrbStack Linux machine or a throwaway workflow run), and verify each produces a binary of the right format (`file` output quoted in a devlog note)
- [ ] 1.2 If any target fails, record the error and the options in a devlog note and stop to ask Emmz (fallback: native runner for that target); otherwise fix nothing and record "all four build"

## 2. Packaging script

- [ ] 2.1 Add `scripts/package-release.sh <version> <target>` producing `devlog-index-<version>-<target>.tar.gz` (`.zip` for windows) containing the binary and `LICENSE`, and verify by running it on a local build and listing the archive contents
- [ ] 2.2 Add checksum generation for a directory of archives (`SHA256SUMS`) and verify with `shasum -a 256 -c SHA256SUMS`

## 3. CI workflow

- [ ] 3.1 Add `.github/workflows/ci.yml` (push and pull_request; ubuntu; pinned Zig 0.16.0; `zig fmt --check src build.zig`; `zig build test --summary all`) and verify with a pushed branch that it goes green
- [ ] 3.2 Verify it goes red on a deliberately unformatted file on a throwaway branch (record the run URL in the devlog note)

## 4. Release workflow

- [ ] 4.1 Add `.github/workflows/release.yml` with `v*` tag and `workflow_dispatch` triggers, a read-only `build` job that cross-compiles the four targets, packages them with the script, smoke-tests the linux-x64 binary, and uploads archives and `SHA256SUMS` as workflow artifacts; verify with a manual dispatch run and download the artifacts
- [ ] 4.2 Add the tag-only `publish` job (`contents: write`, `needs: build`, `gh release create`); verify with a pre-release tag (e.g. `v0.0.1-rc1`) that the Release has four archives and `SHA256SUMS`, then delete the test release and tag
- [ ] 4.3 Verify a dispatch run creates no Release and no tag

## 5. Docs

- [ ] 5.1 Add a "Download a release" section to `README.md` (asset names, checksum verification, macOS quarantine note, where to put the binary) and verify the documented commands work against the 4.2 release
- [ ] 5.2 Update `docs/dependencies.md` if the workflows rely on a tool it doesn't list, and verify `make deps` still passes
