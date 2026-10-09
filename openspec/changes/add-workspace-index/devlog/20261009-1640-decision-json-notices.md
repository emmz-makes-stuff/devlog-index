# Decision: query notices go into the `--json` results too

<!-- Section: 8 · Tasks: 8.2 · Base: 591a328 -->

As built in §7, `query --json` sent its notices ("semantic search skipped: …", "N files changed since
the last update are not indexed yet …") only to stderr. A caller that reads only stdout, or discards
stderr with `2>/dev/null`, would then see keyword-only or stale results as if they were complete. That
breaks the "never present partial results as complete" requirement in workspace-query, Degraded and
empty states. A side agent raised it after §7 landed.

Emmz chose (from three options): **a `notices` field on every result object**. The notices still go to
stderr as well.
- It fits the spec as written: the spec says one JSON object per result with all labels, and nothing
  else on stdout. An extra field is allowed, so no spec delta change is needed.
- Known gap, accepted: a query with zero results prints no lines, so its notices appear only on stderr.
- Rejected:
  - a leading status line `{"notices":…, "results":N}`. It would need the spec's "nothing else on
    stdout" contract changed.
  - keeping the notices on stderr only and documenting it.

Added as task 8.2, because §8 changes the query output anyway.

## Next

- §8, task 8.1: thread expansion (D8), as the section-7-done note describes. Then 8.2: add `notices:
  []const []const u8` to `query.Result` (or set it on each result from `Outcome.notices` before
  `writeJson`), and assert it on every parsed `--json` line in the model-unavailable and stale-index
  tests.
