# Proposal

## Why

The only way to get `devlog-index` today is `./install.sh`, which needs Zig 0.16, the macOS SDK 26
workaround and a full build from source. People who just want the CLI (and the agent skill that calls it)
should be able to download a binary. There is also no CI: format and tests only run when someone remembers
to run `make gates`.

## What Changes

- Add a release workflow, triggered by a `v*` tag push or by manual dispatch, that builds `devlog-index`
  for windows-x64, macos-arm64, linux-x64 and linux-arm64, cross-compiled with Zig from one ubuntu runner.
- A tag push publishes a GitHub Release carrying one archive per target plus a SHA-256 checksums file.
  A manual dispatch runs the same builds and uploads them as workflow artifacts, but publishes nothing.
- Add a CI workflow that runs format and tests on pushes and pull requests.
- Prove first that Zig can cross-compile the vendored C (sqlite, sqlite-vec) and the llama.cpp fork for all
  four targets, particularly macOS without a local SDK and Windows; record the outcome in a devlog note.
- README gains a "Download a release" section next to the source install.

## Capabilities

### New Capabilities
- `release-distribution`: how prebuilt binaries are built, packaged, verified and published, and what CI
  checks on every push and pull request.

### Modified Capabilities

None.

## Impact

- New `.github/workflows/release.yml` and `.github/workflows/ci.yml`.
- Possibly `build.zig` / `Makefile` changes if a target needs a cross-compile fix (decided by the spike).
- `README.md` install section; `docs/dependencies.md` if the workflows need a tool the repo doesn't yet list.
- No change to the CLI's behavior.
