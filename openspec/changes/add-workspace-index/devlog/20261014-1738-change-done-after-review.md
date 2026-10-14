# Change done again: add-workspace-index, after the code-review fixes

<!-- Section: finish · Base: f032e0c · Head: 0d5f3d2 -->

All 15 sections are built and every task is ticked. §13–§15 fix what the code-review run found after
the first change-done note (the 1655 note). §15 came from a side agent's finding against §14.

## Whole-change review of `f032e0c..HEAD`

- **Cross-section contracts hold.**
  - `sources.discover(…, broken)`: `update` collects the broken links into `Report.broken_links`, and
    `main` warns about each one. Freshness and every test call site pass `null`, so `query` and
    `status` stay quiet.
  - `takeSnapshot(…, existing, …)` skips reading a file whose size and mtime match, as freshness
    does, so `update` and `status` agree on what counts as unchanged.
  - The model is pinned by both a commit URL and `pinned_sha256`, through
    `ensureCached` → `download` → `copyVerified`. The cache path doesn't change, so existing caches
    and indexes stay valid.
- **No duplicated abstractions or leftover scaffolding.**
  - The HTML-comment handling in `chunk` now lives only in the line lexer (`Line.comment`). The
    inline copy in `chunkNote` was removed.
  - `Walk.openspec` was removed in §15.
- **Symlink precedence is now consistent.** Every real folder is walked before any link, so a folder
  is indexed at exactly one path: its real one if it has one, otherwise the first link in path order.
  - **Not changed, by design (1731 note):** a symlinked *file* is still indexed at its link path even
    when its target is also indexed directly, because files don't claim a folder. If that ever
    produces duplicate results on the real workspace, it becomes a new change, not a fix here.
- The spec doesn't mention symlinks, model digests or lock messages. These are robustness fixes
  inside the existing requirements, so no delta text needed changing (`VALIDATE_EXIT:0`).

## Gates (at `0d5f3d2`)

```
BUILD_EXIT:0
Build Summary: 20/20 steps succeeded; 110/115 tests passed (5 skipped)
TEST_EXIT:0
FORMAT_EXIT:0
VALIDATE_EXIT:0
GATES_EXIT:0
```

## Next

- Offer Emmz another `code-review` run on `change/add-workspace-index`. Any fixes go in as
  `## 16. Review fixes: …` and are built with the section loop.
- If she declines and no fix sections are open, offer `/opsx:archive` and wait for a yes.
