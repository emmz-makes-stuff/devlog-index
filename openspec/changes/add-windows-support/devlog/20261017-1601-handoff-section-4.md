# Handoff: sections 1–4 landed and pushed; section 5 (install.ps1) is next

<!-- Section: 5 · Tasks: 5.1–5.3 · Base: e4b5f17 -->

Supersedes the `## Next` of the section-4-done note on one point: **`pwsh` is installed on this Mac**
(`/usr/local/bin/pwsh`), so `install.ps1` can be run locally, not only on the Windows runner.

State: branch `change/add-windows-support` is pushed and up to date with origin at e4b5f17, tree clean, no
background tasks. 16 of 20 tasks ticked (§1–§4); 5.1–5.3 and 6.1 remain. No PR is open yet; `ci.yml`'s
`check-windows` has therefore never run, only its twin in `release.yml` has.

Still open for 5.1/5.2: how to test the installer against a real release zip. `v0.1.0` has no zip and the
dry-run artifact needs auth to download. Options to put to Emmz: (a) a local HTTP server serving the
dry-run zip plus a `SHA256SUMS`, with `install.ps1` taking a base-URL override for testing; (b) a pre-release
tag such as `v0.1.1-rc.1`, which publishes a public Release (outward-facing, so ask first). Do not pick (b)
unasked.

## Next

- Section 5, task 5.1: write `install.ps1`; ask Emmz which test route above before 5.2.
- Open a PR for the branch when she's ready, so `ci.yml` runs for the first time; check `check-windows` there.
- Whole-change review nits: list `zip`/`unzip` in docs/dependencies.md; Windows `Quiet` has no automated test.
