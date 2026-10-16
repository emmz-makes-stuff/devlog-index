# release-distribution Specification

## Purpose

Defines how prebuilt `devlog-index` binaries are built, packaged and published for supported platforms, and
what automated checks run on every push and pull request.

## Requirements

### Requirement: Release targets
A release SHALL contain a `devlog-index` binary for each of macos-arm64, linux-x64 and linux-arm64, each
built with `ReleaseFast`.

#### Scenario: All three targets present
- **WHEN** a release build completes
- **THEN** it has produced exactly one binary for each of the three targets, and none is missing

#### Scenario: A target fails
- **WHEN** the build for any one target fails
- **THEN** no GitHub Release is published

### Requirement: Archive packaging
Each target's binary SHALL be packaged as a single archive named after the version and target, containing the
binary and the LICENSE file, as a `.tar.gz`.

#### Scenario: Archive naming
- **WHEN** tag `v1.2.3` is released
- **THEN** the archives are named `devlog-index-v1.2.3-<target>.tar.gz`

#### Scenario: Archive contents
- **WHEN** an archive is extracted
- **THEN** it contains `devlog-index` and `LICENSE`

### Requirement: Checksums
A release SHALL include a `SHA256SUMS` file listing the SHA-256 of every archive.

#### Scenario: Verify a download
- **WHEN** a user runs a SHA-256 check of a downloaded archive against `SHA256SUMS`
- **THEN** it matches the published archive

### Requirement: Tag-triggered publishing
Pushing a tag matching `v*` SHALL publish a GitHub Release for that tag with every archive and `SHA256SUMS`
attached.

#### Scenario: Tag push
- **WHEN** a tag `v0.1.0` is pushed and all builds succeed
- **THEN** a GitHub Release `v0.1.0` exists with three archives and `SHA256SUMS`

### Requirement: Manual dry run
A manual dispatch of the release workflow SHALL run the same builds and packaging as a tag push, upload the
archives and `SHA256SUMS` as workflow artifacts, and SHALL NOT create or modify a GitHub Release or tag.

#### Scenario: Dispatch
- **WHEN** the release workflow is run manually from a branch
- **THEN** the archives are downloadable as workflow artifacts and no Release is created

### Requirement: Continuous checks
On every push and pull request, a CI workflow SHALL run the format check and the test suite and fail if
either fails.

#### Scenario: Unformatted code
- **WHEN** a pull request contains Zig source that `zig fmt --check` rejects
- **THEN** the CI workflow fails

#### Scenario: Failing test
- **WHEN** a pull request breaks a test
- **THEN** the CI workflow fails

### Requirement: Release requires passing checks
A tag-triggered release SHALL run the format check and the test suite, and SHALL NOT publish a GitHub Release
unless both pass.

#### Scenario: Failing check on a tag
- **WHEN** a tag `v*` is pushed and the format check or the test suite fails
- **THEN** no GitHub Release is published

### Requirement: Publishing only from a tag push
Only a push of a tag matching `v*` SHALL publish a GitHub Release; a manual dispatch SHALL NOT, even when
started on a tag ref.

#### Scenario: Dispatch on a tag ref
- **WHEN** the release workflow is run manually with a tag selected as the ref
- **THEN** no GitHub Release is created or modified
