# release-distribution Specification

## Purpose

Defines how prebuilt `devlog-index` binaries are built, packaged and published for supported platforms, and
what automated checks run on every push and pull request.

## Requirements

### Requirement: Release targets
A release SHALL contain a `devlog-index` binary for each of macos-arm64, linux-x64, linux-arm64 and
windows-x64, each built with `ReleaseFast`.

#### Scenario: All three targets present
- **WHEN** a release build completes
- **THEN** it has produced exactly one binary for each of macos-arm64, linux-x64 and linux-arm64, and none
  is missing

#### Scenario: Windows target present
- **WHEN** a release build completes
- **THEN** it has also produced exactly one `devlog-index.exe` for windows-x64

#### Scenario: A target fails
- **WHEN** the build for any one target fails
- **THEN** no GitHub Release is published

### Requirement: Archive packaging
Each target's binary SHALL be packaged as a single archive named after the version and target, containing the
binary and the LICENSE file: a `.tar.gz` for the macOS and Linux targets, and a `.zip` holding
`devlog-index.exe` for windows-x64.

#### Scenario: Archive naming
- **WHEN** tag `v1.2.3` is released
- **THEN** the archives are `devlog-index-v1.2.3-<target>.tar.gz` for macos-arm64, linux-x64 and linux-arm64,
  and `devlog-index-v1.2.3-windows-x64.zip`

#### Scenario: Archive contents
- **WHEN** an archive is extracted
- **THEN** it contains `devlog-index` (`devlog-index.exe` on Windows) and `LICENSE`

### Requirement: Checksums
A release SHALL include a `SHA256SUMS` file listing the SHA-256 of every archive, `.tar.gz` and `.zip` alike.

#### Scenario: Verify a download
- **WHEN** a user runs a SHA-256 check of a downloaded archive against `SHA256SUMS`
- **THEN** it matches the published archive

### Requirement: Tag-triggered publishing
Pushing a tag matching `v*` SHALL publish a GitHub Release for that tag with every archive and `SHA256SUMS`
attached.

#### Scenario: Tag push
- **WHEN** a tag `v0.1.0` is pushed and all builds succeed
- **THEN** a GitHub Release `v0.1.0` exists with four archives and `SHA256SUMS`

### Requirement: Manual dry run
A manual dispatch of the release workflow SHALL run the same builds and packaging as a tag push, upload the
archives and `SHA256SUMS` as workflow artifacts, and SHALL NOT create or modify a GitHub Release or tag.

#### Scenario: Dispatch
- **WHEN** the release workflow is run manually from a branch
- **THEN** the archives are downloadable as workflow artifacts and no Release is created

### Requirement: Continuous checks
On every push and pull request, a CI workflow SHALL run the format check and the test suite on Linux, and the
test suite on Windows x64, and fail if any of them fails.

#### Scenario: Unformatted code
- **WHEN** a pull request contains Zig source that `zig fmt --check` rejects
- **THEN** the CI workflow fails

#### Scenario: Failing test
- **WHEN** a pull request breaks a test
- **THEN** the CI workflow fails

#### Scenario: Test fails only on Windows
- **WHEN** a pull request breaks a test on Windows but not on Linux
- **THEN** the CI workflow fails

### Requirement: Release requires passing checks
A tag-triggered release SHALL run the format check and the test suite on Linux and the test suite on
Windows x64, and SHALL NOT publish a GitHub Release unless all pass.

#### Scenario: Failing check on a tag
- **WHEN** a tag `v*` is pushed and the format check or the test suite fails on either OS
- **THEN** no GitHub Release is published

### Requirement: Publishing only from a tag push
Only a push of a tag matching `v*` SHALL publish a GitHub Release; a manual dispatch SHALL NOT, even when
started on a tag ref.

#### Scenario: Dispatch on a tag ref
- **WHEN** the release workflow is run manually with a tag selected as the ref
- **THEN** no GitHub Release is created or modified

### Requirement: Windows installer
The repository SHALL provide `install.ps1`, which downloads the windows-x64 archive of the latest release (or
of a version given as a parameter), verifies it against `SHA256SUMS`, and installs `devlog-index.exe` into a
per-user directory without administrator rights.

#### Scenario: Install latest
- **WHEN** a user runs `install.ps1` on Windows x64 with no parameters
- **THEN** `devlog-index.exe` from the latest release is installed to a per-user directory, and the script
  says whether that directory is on `PATH`

#### Scenario: Checksum mismatch
- **WHEN** the downloaded archive's SHA-256 differs from its `SHA256SUMS` entry
- **THEN** the script installs nothing, removes the download, and exits non-zero naming both hashes
