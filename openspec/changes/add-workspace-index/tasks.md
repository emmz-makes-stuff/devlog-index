# Tasks

## 1. Scaffold and vendored stack

- [x] 1.1 Create `build.zig` / `build.zig.zon` (Zig 0.16, executable `devlog-index`, `test` step) depending on the same pinned `daemonicai/llama.cpp.zig` commit as memlite; verify `zig build` succeeds and `zig-out/bin/devlog-index --help` prints a usage line
- [x] 1.2 Copy memlite's `third_party/sqlite` and `third_party/sqlite-vec` (with its musl patch) and `VERSIONS.md`, compile them into the build, and add a test that opens an in-memory DB, creates an FTS5 table and a `vec0` table; verify `zig build test --summary all` passes
- [x] 1.3 Add `.gitignore` (`zig-out/`, `.zig-cache/`) and a stub `README.md` naming the commands; verify `zig fmt --check src build.zig` exits 0

## 2. Embedding engine and the latency budget

- [x] 2.1 Adapt memlite's `model`, `model_url`, `download` and `embed` modules with provenance headers; pin `nomic-embed-text-v1.5` Q5_K_M and the model cache at `~/.devlog-index/models/`; apply `search_document:` / `search_query:` prefixes with title-first truncation (D2); verify unit tests for prefixing and truncation pass, and model-gated tests (with `DEVLOG_INDEX_TEST_MODEL`) produce a unit-length vector of the model's dimension
- [x] 2.2 Add a hidden `bench-cold` command that loads the model, embeds one query and scores it against 3,200 random vectors in a `vec0` table; verify on this machine that a fresh process completes in < 1 s and record the measured times in a devlog note (stop and raise it with Emmz if the budget is missed)

## 3. Workspace config

- [x] 3.1 Implement config parsing (`devlog-index.json`: name, members) and walk-up resolution with nearest-wins and the "no workspace" error naming `init` (workspace-config spec); verify unit tests cover nested configs, missing members and no-config
- [x] 3.2 Implement `init <name> <member>…` refusing to overwrite; verify an integration test creates a config in a temp dir and a second `init` fails naming the file unchanged

## 4. Fixture workspace, discovery and chunking

- [x] 4.1 Commit a synthetic fixture workspace under `test/fixtures/workspace/` (two declared members plus an undeclared sibling; an archived change with a reversal thread referenced by filename, by `HHMM` time and by `§N-done`; a main spec and an archived delta of it; an active change with a delta; a legacy `DEVLOG.md`) with a README describing what each file exercises; verify the files exist and the README lists each scenario
- [x] 4.2 Implement source discovery per the Indexed sources requirement (archived deltas, legacy `DEVLOG.md` and undeclared repos excluded); verify a test against the fixture lists exactly the expected files
- [x] 4.3 Implement chunking and classification (D7): note paragraphs ≥ 80 words with title prefix and section comment stripped, spec per requirement plus purpose, other artifacts per `##`; kind and time from note filenames; verify unit tests for each rule, including the `stopped` example from the corpus-indexing spec

## 5. Index storage and incremental update

- [x] 5.1 Implement the schema (D3): `settings`, `files`, `passages`, FTS5 (porter), `vec0` with the model dimension; model URL/dimension pinned and mismatch refused naming `update --rebuild`; verify unit tests for bootstrap and mismatch
- [x] 5.2 Implement `update` and `update --rebuild`: hash comparison, add/change/delete handling, archived-state changes, whole-workspace refresh from any member, single commit at the end, model downloaded on first need with progress, and failure without changing the index when the model can't load; verify integration tests on a temp copy of the fixture cover every corpus-indexing Incremental update scenario (embeddings stubbed when no model is set)
- [x] 5.3 Run `update` on the real workspace after creating its config with `init`; verify it completes, report passage counts and full-build time in a devlog note, and confirm a second run reports zero files changed in under 2 s

## 6. Status and freshness

- [x] 6.1 Implement change detection (size + mtime, hash on mismatch) and `status [--json]` reporting workspace, per-member counts or missing, changed-file count, last update time and model presence (D9); verify integration tests for a stale index (two notes added → "2 files changed") and a missing member

## 7. Query

- [x] 7.1 Implement lexical retrieval via FTS5 `bm25()` with the query converted into a quoted OR of terms so punctuation cannot inject operators; verify unit tests including a query containing `"`, `*`, `-` and `:`
- [x] 7.2 Implement semantic retrieval (exhaustive cosine via `vec0`) and the union merge (D6): k per method (default 5, `--k`), dedupe, `methods` labels, ordering both-first then alternating; verify unit tests on a hand-built index with known vectors
- [x] 7.3 Implement result labelling and output: text by default, `--json` one object per line with all labels, text and thread; errors only on stderr; verify an integration test parses every stdout line of `--json` as JSON
- [x] 7.4 Implement degraded and empty states: missing index → non-zero naming `update`; model unavailable → lexical results plus an explicit "semantic search skipped: <reason>" notice; stale index notice with the changed-file count; verify integration tests for all three
- [x] 7.5 With the model, run the cold query on the real workspace; verify < 1 s wall-clock from process start (workspace-query Query latency) and record the timing in a devlog note

## 8. Thread expansion

- [x] 8.1 Implement thread expansion (D8): later notes in the same change referring to a result by filename, by `HHMM` next to "note", or by `§N-done` / `section N done` for `section-N-done` notes; attach as thread entries in time order; verify fixture tests for each reference form and that a same-time mention in another change is not threaded
- [x] 8.2 Carry query notices in `--json`: add `"notices": [...]` (semantic search skipped, stale index; empty when none) to every result object, still also on stderr; verify the model-unavailable and stale-index tests assert the field on every parsed `--json` line

## 9. Retrieval evaluation

- [x] 9.1 Implement `eval`: read `.devlog-index/golden.json`, run each question with defaults, report ranks, distinguish "not indexed" from "not ranked", exit 0 only if all expected sources are in the top ten, with entries marked as known misses reported but not failing (and reported as unexpectedly found when they land in the top ten); verify integration tests with a fixture golden set covering all-found, one-missed, missing golden set, not-indexed, and a known miss both still missing and now found
- [x] 9.2 Seed `<real-workspace>/.devlog-index/golden.json` with five questions in the spike's shapes and their expected sources (outside this repo; the spike's own questions were never recorded), marking the paraphrase question as a known miss, run `cd <real-workspace> && devlog-index eval`, and tune the chunk threshold and k against it if needed; verify `eval` exits 0, or record each remaining miss and the reason in a devlog note and stop to agree it with Emmz

## 10. Install and integration

- [x] 10.1 Add `install.sh` (ReleaseFast build, copy to `~/.local/bin`) and complete `README.md` with install, `init`, `update`, `query`, `status`, `eval`, the `--json` line contract and where workspace data lives; verify a fresh install runs `devlog-index status` from inside a member repo of the real workspace and the README's commands work as written
- [x] 10.2 End-to-end check from a member repo: add a devlog note in one real-workspace member, run `update` from another, and query for it; verify the new note is returned with correct labels and that `zig build`, `zig build test --summary all` and `zig fmt --check src build.zig` all exit 0

## 11. Review fixes: correctness

- [x] 11.1 Load the model once per `ModelProvider`: `get` returns the already-loaded embedder instead of loading (and leaking) another model; verify with a model-gated test that repeated `get` calls keep the same loaded model (the stub cannot show this: each `get` is its own load), and state the contract on `Provider`
- [x] 11.2 Every failure names its cause: each command's `run` wrapper fills a default message whenever its diag is empty, and the vector-length (update), `last_update` (status) and `dim` (query) failures get their own messages; verify with tests that no failure path leaves the message empty
- [x] 11.3 Reject a workspace whose members share a folder name (it is the `member` label), naming both; verify with a config test
- [x] 11.4 Reword the corpus-indexing "Model mismatch" scenario (and design D3) to the agreed behaviour: `update` refuses; `query` returns lexical results with a notice naming both models and the rebuild command; verify `make validate`
- [x] 11.5 Re-time the cold query on the real workspace with the installed ReleaseFast binary, now that thread expansion runs per result; verify it is within the 1 s budget and record the timings in a devlog note

## 12. Review fixes: CLI and scaffolding

- [x] 12.1 Add CLI integration tests (D10) that run the built binary against a temp copy of the fixture: `query --json` writes only JSON lines to stdout with notices on stderr; exit codes are 0 on success, 1 on an error and on a failed `eval`, 2 on a usage error; verify they run in `zig build test`
- [x] 12.2 Remove the `bench-cold` spike (`src/bench.zig` and its `main.zig` branch); its measurements stay in the §2 and §7 devlog notes
- [x] 12.3 Tidy drift in `main.zig` and below: one usage-exit path for every command; `query` rejects unknown `--` flags instead of treating them as text; drop the unused `update.Report.missing_members`; fix the stale `Embedder.embed` doc comment; close SQLite connections with `sqlite3_close_v2`; verify `make gates`

## 13. Review fixes: index integrity and model pinning

- [x] 13.1 `update` reads the `files` table and decides inserts, updates and deletes only after `BEGIN IMMEDIATE`, so a concurrent `update` can't make it work from a stale snapshot; a second writer waits out the busy timeout and fails with a message saying the index is locked by another update, leaving it unchanged; test by holding the write lock from another connection
- [x] 13.2 `query` skips a ranked passage whose file row is missing instead of failing the whole query, and adds a notice naming the rebuild command; test with a hand-made orphan passage
- [x] 13.3 `swapIn` deletes any leftover `-wal`/`-shm`/`-journal` next to the live path before renaming a rebuilt index into place where there is no live index; test with stale sidecar files present
- [x] 13.4 Pin the model by content: the pinned URL names a Hugging Face commit revision instead of `main`, and the download verifies a pinned SHA-256 before the file enters the cache (a mismatch is an error naming both hashes and leaves no cached file); update D2, `docs/dependencies.md` if affected, and the corpus-indexing spec (a new "Model pinned by content" requirement with a hash-mismatch scenario); hermetic test of the hash check; verify `make gates`

## 14. Review fixes: indexing and query edge cases

- [x] 14.1 `update` skips reading and hashing a file whose size and mtime match its `files` row, as freshness does; test that an unchanged update reads no file bodies and still detects a same-size edit with a new mtime
- [x] 14.2 Discovery follows symlinked files and directories under a member's `openspec/`, with a guard against loops (a directory target already visited is skipped) and a warning for each broken link; test with a symlinked note, a symlinked spec directory, a loop and a broken link
- [x] 14.3 The FTS query builder splits terms on Unicode punctuation (dashes, curly quotes, ellipsis and the like), not only ASCII; test `retry—backoff` and `don’t`
- [x] 14.4 The chunker treats everything inside an HTML comment as comment, fences included, so a fenced block inside `<!-- … -->` neither leaks into passages nor keeps the comment open; test both; verify `make gates`

## 15. Review fixes: symlink precedence

- [x] 15.1 Discovery walks every member's real folders first, without following symlinked folders, then follows the queued symlinked folders in path order (links found inside them are queued too), so a folder reachable both directly and through a link is always indexed at its real path; test a sibling link (`specs/alias` → `specs/auth`) and a link from `changes/` into `specs/`, both indexed under the real path only; verify `make gates`

## 16. Review fixes: index swap and concurrency

- [x] 16.1 `update --rebuild` holds an exclusive, non-blocking lock on `index.db.rebuild.lock` for the whole rebuild, so a second rebuild fails cleanly ("locked by another devlog-index update; the index is unchanged") instead of deleting the first one's files; test two overlapping rebuilds
- [x] 16.2 `swapIn` falls back to deleting the live index and its sidecar files and renaming the rebuilt one into place when the live file exists but cannot be opened or read as a database, so `--rebuild` repairs a corrupt index as the error messages promise; test with a live `index.db` that is not a database
- [x] 16.3 `swapIn` treats only `FileNotFound` from `access(live)` as "no index yet"; any other error fails the update without deleting anything; test that a non-`FileNotFound` access error leaves the live files in place
- [x] 16.4 A query ranks and loads its passages inside one read transaction on its connection, so an update or rebuild that commits mid-query cannot change the ids between ranking and loading; test that a commit between rank and load does not change the results or produce an orphan notice; verify `make gates`

## 17. Review fixes: chunking and threads

- [x] 17.1 Fence tracking records the opening fence's character (and length) and closes only on a matching fence, per CommonMark, so a `~~~` line inside a ```` ``` ```` block (and the reverse) stays inside the block; test in a note and in a design section
- [x] 17.2 A comment that closes on the same line it opens keeps the text after `-->` (and a multi-line comment keeps the text after its closing `-->`); test `<!-- Section: 3 --> Decided …` and a multi-line comment
- [x] 17.3 Thread expansion includes later notes written in the same minute as the result note, ordering by (note time, path) and excluding the result itself; test a stopped note and an answer that share a minute; verify `make gates`

## 18. Review fixes: shared change detection and FTS storage

- [x] 18.1 One helper, shared by `freshness.detect` and `update.takeSnapshot`, loads the indexed `files` rows, lists missing members, and decides whether a file is unchanged (size and mtime match a well-formed hash) or vanished; both callers use it, and their existing tests still pass unchanged
- [x] 18.2 `passages_fts` becomes an external-content FTS5 table over `passages` (`content='passages'`, `content_rowid='id'`, same tokenizer), with deletes through the FTS `'delete'` command; `schema_version` goes to `2`, so an old index is refused with the rebuild message; test that lexical ranking is unchanged on the fixture and that a version-1 index is refused; verify `make gates`

## 19. Review fixes: design wording and FTS test

- [x] 19.1 design.md D8 says a note from the same minute as the result counts as later (filenames cannot order notes within a minute), matching §17.3
- [x] 19.2 The re-chunk test's `count(passages_fts) == count(passages)` check, always true with external content, becomes an FTS5 `integrity-check`; verify `make gates`
