# Tasks

## 1. Cross-compile spike

- [x] 1.1 Cross-compile `zig build -Doptimize=ReleaseFast -Dtarget=<t>` for `aarch64-macos`, `x86_64-linux` and `aarch64-linux` on an ubuntu-24.04 runner (throwaway spike workflow run 38913803931), and verify each produces a binary of the right format (`file` output quoted in a devlog note)
- [x] 1.2 Record the spike outcome in a devlog note (three targets build; Windows fails in `Quiet`/`HOME`, deferred; the Rosetta OrbStack failure), delete `.github/workflows/spike-cross.yml`, and verify it is gone from the branch

## 2. Packaging script

- [x] 2.1 Add `scripts/package-release.sh <version> <target>` producing `devlog-index-<version>-<target>.tar.gz` containing the binary and `LICENSE`, and verify by running it on a local build and listing the archive contents
- [x] 2.2 Add checksum generation for a directory of archives (`SHA256SUMS`) and verify with `shasum -a 256 -c SHA256SUMS`

## 3. CI workflow

- [x] 3.1 Add `.github/workflows/ci.yml` (push and pull_request; ubuntu; pinned Zig 0.16.0; `zig fmt --check src build.zig`; `zig build test --summary all`) and verify with a pushed branch that it goes green
- [x] 3.2 Verify it goes red on a deliberately unformatted file on a throwaway branch (record the run URL in the devlog note)

## 4. Release workflow

- [x] 4.1 Add `.github/workflows/release.yml` with `v*` tag and `workflow_dispatch` triggers, a read-only `build` job that cross-compiles the three targets, packages them with the script, smoke-tests the linux-x64 binary, and uploads archives and `SHA256SUMS` as workflow artifacts; verify with a manual dispatch run and download the artifacts
- [x] 4.2 Add the tag-only `publish` job (`contents: write`, `needs: build`, `gh release create`); verify with a pre-release tag (e.g. `v0.0.1-rc1`) that the Release has three archives and `SHA256SUMS`, then delete the test release and tag
- [x] 4.3 Verify a dispatch run creates no Release and no tag

## 5. Docs

- [ ] 5.1 Add a "Download a release" section to `README.md` (asset names, checksum verification, macOS quarantine note, where to put the binary, and that Windows isn't yet supported) and verify the documented commands work against the 4.2 release
- [ ] 5.2 Update `docs/dependencies.md` if the workflows rely on a tool it doesn't list, and verify `make deps` still passes
