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

- [x] 5.1 Add a "Download a release" section to `README.md` (asset names, checksum verification, macOS quarantine note, where to put the binary, and that Windows isn't yet supported) and verify the documented commands work against the 4.2 release
- [x] 5.2 Update `docs/dependencies.md` if the workflows rely on a tool it doesn't list, and verify `make deps` still passes

## 6. Review fixes: publish safety, test gating, hardening

- [ ] 6.1 Publish only on a tag *push*: add `github.event_name == 'push'` to the `publish` condition, so a manual dispatch started on a tag ref can't create a Release; verify with a dispatch run on a throwaway tag ref that `publish` is skipped, then delete the tag
- [ ] 6.2 Gate publishing on the checks: add a `check` job to `release.yml` (format check and tests, as in `ci.yml`), make `publish` need both `check` and `build`, and add the "Release requires passing checks" requirement to the spec; verify the job runs on a dispatch and `make validate` is green
- [ ] 6.3 Make release builds clean: replace the `restore-keys` prefix fallback in `release.yml` with an exact-key cache; limit `ci.yml`'s `push` trigger to `main` and `v*` tags (PRs still run via `pull_request`); replace `"${flags[@]}"` with an `if` that is safe under `set -u`; verify with a pushed branch and a dispatch run
- [ ] 6.4 Harden `scripts/test-release-scripts.sh`: assert positively that the archive listing shows owner `root`/`0/0` (and that `tar -tzvf` succeeded) instead of the grep-finds-nothing check; confirm by temporarily dropping the owner flags and seeing the test fail; and add the "archive in the current directory" note to the README checksum snippet
