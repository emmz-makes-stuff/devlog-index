# Review: whole change (f10f567..6681ef2)

<!-- Section: review · Base: 6681ef2 -->

Two read-only review passes, one for spec coverage and one for code quality. I checked their bug
findings against the code myself. 36 of 43 scenarios have code and a test. Three are model-gated or
manual. The rest became fix sections.

## Agreed with Emmz (2026-10-14)

- **§11 Review fixes: correctness** and **§12 Review fixes: CLI and scaffolding** were added to
  `tasks.md` as drafted.
- **Model mismatch:** change the spec, not the code. `query` keeps returning lexical results with a
  notice; `update` still refuses (11.4).
- **Scope:** fix the bugs and the scaffolding. The structural refactors are deferred (below).
- **Thread repeated on each passage of a note:** stays deferred. Each `--json` line stays self-contained.
- **Run the `code-review` skill** on the branch after §12, before archiving.

## Findings behind the fix sections

- **Model loaded per question (11.1):** `ModelProvider.get` (`update.zig:576`) loads the model on every
  call. `query.embedQuery` calls it on every `rank()`, and `eval` calls `rank()` once per question. So
  5 questions load the ~99 MB GGUF 5 times and leak 4 copies. This came in with 9.1. `update` never hit
  it because `Writer` caches its embedder.
- **Empty error messages (11.2):** a known error returned with an empty diag prints `devlog-index: `
  and nothing more. Sites: `update.zig:486` (vector length), `status.zig:80` (`last_update`),
  `query.zig:152` (`dim`).
- **Member folder names collide (11.3):** `sources.zig:111` labels a member by `basename(path)`, but
  `workspace.validate` only rejects identical resolved paths.
- **The CLI binary has no test (12.1):** D10 calls for one. `--json` stdout purity and exit codes were
  only checked by hand in §10.
- **`bench-cold` (12.2):** the §2 spike. Task 7.5 timed the real `query` since then.

## Deferred, not planned

- Seven identical `Diag { message }` structs, with callers copying `.message` between them.
- `Embedder`, `Provider`, `ModelProvider` and `hashHex` live in `update.zig`, so `update` and
  `freshness` import each other. They belong in an embedding module.
- Index, golden and model paths are built in several places, and the `HOME` lookup is repeated 4
  times in `main.zig`.
- "Missing members" is computed three times. `readFailed` and the schema- and model-mismatch
  messages are each written twice.
- Error wording varies: `"{path}: cannot read (E)"` vs `"cannot read {path} (E)"`.
- A zero-result `query --json` leaves stdout empty, so its notices reach stderr only (accepted in
  the 1640 decision-json-notices note).
- The model download path has no hermetic test (code adapted from memlite).
- Thread repetition, and "task 7.3"-style references (§9 note).

## Next

- §11, task 11.1: load the model once per `ModelProvider`.
