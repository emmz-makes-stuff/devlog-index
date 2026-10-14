# Review: second code-review run, findings and plan for §16–§18

<!-- Section: review · Base: e89bf12 -->

`code-review change/add-workspace-index` ran after the 1738 change-done note and reported 10 findings.
None of them was verified in the code by the review itself. Verify each one while building its task.

## Findings and Emmz's call (2026-10-14)

- **§16, index swap and concurrency (accepted):**
  1. Two `--rebuild` runs share `index.db.rebuild` and delete each other's files, so one can swap in
     an empty database.
  2. `--rebuild` can't repair a corrupt live index: `sqlite3_backup` into it fails with NOTADB.
  3. `swapIn` takes any `access(live)` error to mean "no index" and deletes the live files.
  4. A query's rank and load aren't in one read transaction, so a commit in between changes the ids.
- **§17, chunking and threads (accepted):**
  5. A `~~~` line closes a ```` ``` ```` fence, and the reverse.
  6. Text after `-->` on the comment's line is dropped.
  7. Thread expansion uses `note_time > ?` at minute precision, so a later note from the same minute
     is left out.
- **§18, refactors (accepted):**
  9. `freshness.detect` and `update.takeSnapshot` contain the same rule for deciding whether a file
     changed.
  10. `passages_fts` stores a second copy of every passage's text.
- **Declined:** finding 8 asked to index a symlinked file only once, at its real path. Emmz kept the
  1731 decision: only folders compete for a single path, so file links stay indexed at their link
  path.

## Choices I made in the task text (Emmz agrees them with the tasks)

- 16.1 uses a lock file, so a second rebuild **fails** instead of waiting. A second plain update
  already does the same (`SqliteBusy` → "locked by another devlog-index update").
- 18.2 changes the stored index format, so `schema_version` goes to `2`. Existing indexes, including
  the real workspace's, will be refused until `update --rebuild` runs.

## Next

- Once Emmz agrees the tasks, start §16 with task 16.1 in `src/update.zig` (`runInner`). Note the base
  commit first.
