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

- [ ] 10.1 Add `install.sh` (ReleaseFast build, copy to `~/.local/bin`) and complete `README.md` with install, `init`, `update`, `query`, `status`, `eval`, the `--json` line contract and where workspace data lives; verify a fresh install runs `devlog-index status` from inside a member repo of the real workspace and the README's commands work as written
- [ ] 10.2 End-to-end check from a member repo: add a devlog note in one real-workspace member, run `update` from another, and query for it; verify the new note is returned with correct labels and that `zig build`, `zig build test --summary all` and `zig fmt --check src build.zig` all exit 0
