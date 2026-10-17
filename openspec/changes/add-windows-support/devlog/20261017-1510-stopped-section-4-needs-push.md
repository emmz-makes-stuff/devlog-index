# Stopped: section 4 needs a push to verify on GitHub

<!-- Section: 4 · Tasks: 4.1–4.4 · Base: 3c3972c -->

Workflow edits are written but **uncommitted and unticked**, because 4.1–4.3 each say "verify on GitHub" and
that needs the branch pushed (and a `workflow_dispatch` run), which is outward-facing and not authorized yet.

What's in the working tree:
- `ci.yml`: new `check-windows` job (runs-on `windows-2025`, pwsh): downloads Zig 0.16.0 windows zip, checks
  SHA-256 `68659eb5…75a7e` (taken from ziglang.org's download index.json; the same lookup reproduced the
  Linux hash already pinned), runs `zig build test --summary all`.
- `release.yml`: the same `check-windows` job; `windows-x64:x86_64-windows` added to the build loop (the
  `file` call now globs `devlog-index*`); new `smoke-windows` job that downloads the `release` artifact,
  unzips the windows-x64 archive and runs `devlog-index.exe --help`, requiring `Usage: devlog-index`;
  `publish` now needs `[check, check-windows, build, smoke-windows]`, its `if` unchanged (tag push only).
- Chose `windows-2025` over `windows-latest` to match the Linux jobs pinning `ubuntu-24.04`; design said
  "windows-latest", same intent.
- `actionlint`: ACTIONLINT_EXIT:0. `make gates`: GATES_EXIT:0.

Risks to watch on the first Windows run: (1) `cli_test.zig` spawns the exe with an environment containing
only HOME/USERPROFILE; Windows processes sometimes need `SystemRoot`, so those tests may fail there.
(2) symlink tests may skip if the runner can't create links. (3) the model download path is untested.

Question for Emmz: may I push `change/add-windows-support` to origin and trigger the release workflow by
`workflow_dispatch` as a dry run (no tag, nothing published)?

## Next

- On a yes: commit nothing yet; push the branch, watch `ci` and a dispatch of `release` with `gh run watch`
  (unsandboxed, per the sandbox notes), fix any Windows-only failures, then tick 4.1–4.4, write the
  section-4-done note and make the §4 commit.
- On a no: tick nothing; the edits stay in the tree for review.
