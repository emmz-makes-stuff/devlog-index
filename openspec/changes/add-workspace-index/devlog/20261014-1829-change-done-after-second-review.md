# Change done again: add-workspace-index, after the second review's fixes

<!-- Section: finish · Base: e89bf12 · Head: 7b50621 -->

All 18 sections are built and every task is ticked. §16–§18 fix the second code-review run's
findings (the 1744 note). Finding 8, about symlinked files, was declined.

## Whole-change review of `e89bf12..HEAD`

- **Change detection has one path.** `freshness.current` is the only stat and hash of a source file.
  The other `statFile` call is `sources.Walk`'s symlink-kind check, and the other `hashHex` calls
  hash passages.
- **No scaffolding is left over.** `query.test_between_rank_and_load` runs only under
  `builtin.is_test`. The rebuild lock is held through `swapIn`, and a plain update that collides
  with the swap gets the existing `SqliteBusy` message.
- **The lexer's recursion ends.** `chunk.Lines.read` recurses only on a strictly shorter remainder,
  after `<!--` or after `-->`.
- **D3 still holds:** "an FTS5 table over passage text" is still true with external content.
- **Two small items are open, waiting for Emmz's call:**
  1. **D8 drift.** design.md says "later notes only", but §17.3 threads same-minute notes (the 1809
     note). The design text should say that same-minute notes count as later.
  2. **A stale assertion.** In `update.zig`, the test "a changed file is re-chunked, reusing vectors
     of unchanged passages" ends with `count(passages_fts) == count(passages)`. With external
     content, that count reads `passages`, so the check is always true. It should become
     `INSERT INTO passages_fts(passages_fts, rank) VALUES ('integrity-check', 1)`.

## Gates (at `7b50621`)

```
BUILD_EXIT:0
Build Summary: 20/20 steps succeeded; 119/124 tests passed (5 skipped)
TEST_EXIT:0
FORMAT_EXIT:0
VALIDATE_EXIT:0
GATES_EXIT:0
```

## Next

- Ask Emmz whether the two open items become `## 19. Review fixes: design wording and FTS test`. If
  yes, build it with the section loop.
- Then offer `code-review` again or `/opsx:archive`, and wait for a yes.
- Reminder for Emmz: the real workspace needs `devlog-index update --rebuild` (schema 2).
