# Design

## Context

Greenfield: the repo holds only `openspec/` and `docs/`. See proposal.md for motivation and the four
specs for behaviour. The foundational calls are recorded as ADR-0001 to ADR-0004 in `docs/adrs/`; this
document collects every decision, including the smaller ones, and the gate commands.

Two of Emmz's projects bound the approach:

- **memlite** (`~/github/daemonicai/memlite`, Zig 0.16): vendored SQLite 3.53.1, sqlite-vec 0.1.9 (musl
  patch), md4c; llama.cpp via the `daemonicai/llama.cpp.zig` fork pinned in `build.zig.zon`; modules
  `model.zig` (load GGUF), `embed.zig` (single-text pooled, L2-normalised embedding), `download.zig` /
  `model_url.zig` (first-run model fetch to a cache), `db.zig` (schema bootstrap with the vector
  dimension substituted). It fuses results with RRF, which this design rejects.
- **devlog** (`~/github/daemonicai/devlog`, Zig 0.16): CLI not MCP; `--json` one line per invocation;
  BM25 only. Evidence here (ADR-0004) shows BM25 alone misses Emmz's own example questions.

The first real workspace is client work: its name, member repos and location are kept out of this repo.
`<real-workspace>` below stands for its root folder on Emmz's machine; examples in the specs use a
made-up `acme` workspace.

A throwaway spike on 2026-10-09 against the first real workspace measured: 3,222 passages with the chosen
chunking; full embed ~48 s (Ollama, same model family); query ~50 ms warm. Ranks are in ADR-0004.

## Goals / Non-Goals

**Goals:**
- One self-contained binary; no daemon; nothing leaves the machine.
- Cold query < 1 s on the real workspace; incremental update proportional to what changed.
- Retrieval quality measured by a golden set, not judged by eye.
- Hermetic unit and integration tests that need neither the model nor client content.

**Non-Goals:**
- Approximate-nearest-neighbour indexing (exhaustive scoring is milliseconds at this size).
- Answer synthesis inside the tool.
- Watching the filesystem or running in the background.
- Cross-platform release packaging (macOS arm64 is the only target for v1; nothing should preclude
  Linux later).

## Decisions

### D1. Language: Zig 0.16, reusing memlite's stack (ADR-0001)
Copy memlite's vendored `third_party/` (SQLite, sqlite-vec with its musl patch) and adapt its `model`,
`embed`, `download` and `model_url` modules, with a provenance header naming the memlite commit each was
copied from. Depend on the same pinned `llama.cpp.zig` fork commit.
*Alternatives:* .NET 10 + Ollama (recommended by Claude, rejected by Emmz: daemon dependency); .NET +
ONNX in-process (untested model, native interop); TypeScript/Bun (second runtime, no gain).
*Why copy rather than depend:* memlite is an application, not a package; extracting a shared library
now is premature for two consumers.

### D2. Embedding model: nomic-embed-text-v1.5 Q5_K_M GGUF, with task prefixes
The model memlite already downloads (~99 MB), in the same family as the spike's. Passages are embedded
as `search_document: <text>` and queries as `search_query: <text>`, as the spike did; the model is
trained with these prefixes. Inputs longer than the model's context are truncated, with the title first
so it always survives.
*Alternatives:* a smaller model (bge-small) — untested here; would have to re-earn the spike's ranks.

### D3. Storage: one SQLite database, FTS5 + sqlite-vec (ADR-0002)
Tables: `settings` (model URL, dimension, schema version), `files` (member, path, content hash, kind,
change, archived, note time, last indexed), `passages` (file id, ordinal, text, title), an FTS5 table
over passage text (porter tokenizer), and a sqlite-vec `vec0` table over passage vectors. Each file's
re-index happens in one transaction; the whole update commits at the end, so an interrupted update leaves
the previous index intact. Model URL or dimension mismatch → refuse with the rebuild command
(`update --rebuild`).
*Alternatives:* BLOB vectors with hand-written cosine; flat files + in-memory BM25 (both in ADR-0002).

### D4. Workspace config and location (ADR-0002)
`devlog-index.json` at the workspace root: `{ "name": "acme", "members": ["infra", "api", …] }`, parsed
with `std.json`. Resolution walks up from the working directory; nearest wins. Beside it, a
`.devlog-index/` directory holds `index.db` and `golden.json`. The model cache is per-user:
`~/.devlog-index/models/` (memlite's layout), shared by all workspaces.
*Alternatives:* inferring members from the parent folder (accidental scratch repos); ADO project (one
member is in another project, one has no remote); a per-user index registry (two places to look).

### D5. Interface: CLI (ADR-0003)
Commands: `init <name> <member>…`, `update [--rebuild]`, `query [--json] [--k N] "<text>"`, `status
[--json]`, `eval`. Errors go to stderr with a non-zero exit; `--json` writes only JSON objects to stdout,
one per line. Install: `zig build -Doptimize=ReleaseFast` then copy to `~/.local/bin` via `install.sh`
(memlite pattern).
*Alternative:* MCP stdio server — rejected for context cost and per-project config; can be layered on
the same core later.

### D6. Retrieval: union of BM25 and vector top-k (ADR-0004)
Run FTS5 `bm25()` for the top k (default 5) and exhaustive cosine over the `vec0` table for the top k;
merge, de-duplicating by passage, recording `methods: ["lexical","semantic"]`. Order: passages found by
both first, then alternating lexical/semantic by their own rank. Stop words are left to FTS5's query
syntax: the query text is converted into an OR of its terms, with quoting so punctuation cannot inject
FTS5 operators.
*Alternatives:* RRF (memlite; buries single-method answers — measured), BM25 only, vector only.

### D7. Chunking and classification
- Devlog note: split on blank lines, accumulate paragraphs until ≥ 80 words, prefix each passage with the
  note's `# ` title; the `<!-- Section … -->` comment is metadata, not passage text. Kind from the slug's
  first word (`decision`, `stopped`, `section`, `answer`, `change`, `review`; else `note`); time from
  `YYYYMMDD-HHMM`.
- Spec / spec delta: one passage for `## Purpose`, one per `### Requirement:` block including its scenarios.
- proposal / design / tasks: one passage per `##` section.
- Markdown is treated as text; md4c is not needed for v1.
Tuning these numbers is done against the golden set, not by intuition.

### D8. Thread expansion
At query time, for each devlog result, scan later notes in the same change (one indexed query on
`files`) for references to it: its filename (with or without `.md`), its `HHMM` time as a standalone
four-digit token next to "note", or its section as `§N-done` / `section N done` when the result
is a `section-N-done` note. Matching notes are attached as thread entries in time order, each with the
passages that make the reference. Matching is deliberately conservative: same change only, later notes
only, and no bare `§N` (it appears in almost every later note).
*Alternative:* resolve references at index time into a link table — rejected for v1 because the
reference patterns will be tuned, and a query-time scan over one change's notes is cheap (tens of files).

### D9. Freshness without a watcher
`status` and `query` compare each indexed file's size and modification time (and content hash only if
those differ) with the filesystem to count changed files, so a stale index is reported, not silently
used. The follow-up skill change makes `update` routine at section done and pickup.

### D10. Testing
- Unit tests per module (`zig build test`).
- A synthetic fixture workspace under `test/fixtures/workspace/` committed to this repo: two members, an
  archived change with a reversal thread (filename, time and section references), a main spec plus an
  archived delta of it, an active change with a delta, a legacy `DEVLOG.md`, and an undeclared sibling
  repo. Integration tests run the CLI against a temp copy of it.
- Model-dependent tests (embedding, semantic ranking, end-to-end query) are skipped unless
  `DEVLOG_INDEX_TEST_MODEL` points at a GGUF file (memlite's pattern), so `zig build test` stays hermetic.
- The real workspace's golden set lives at `<real-workspace>/.devlog-index/golden.json`, seeded with five
  questions in the spike's five shapes (the spike's own questions were never recorded); never committed
  here (client content). The paraphrase question, which shares no key words with its note, is marked as
  a known miss, so `eval` is a usable gate from the start while that
  question still measures paraphrase handling (retrieval-eval, Known misses).
- `golden.json` is `{"questions": [{"question": "…", "expected": ["<member>/openspec/…"], "known_miss":
  false}]}`, with paths relative to the workspace root and no unknown fields. `eval` grades the default
  top ten. For a source outside it, `eval` shows the source's rank in each method's own list, searched to
  depth 100. `eval` fails when semantic search can't run, because lexical-only ranks aren't the default
  query's (decided with Emmz, 2026-10-14).

### D11. Gate commands
Single stack; run from the repo root. All are non-interactive and exit non-zero on failure. On macOS,
`make` runs build and test with `ZIG_LIBC` pointing at SDK 26.x headers: Zig 0.16.0's bundled libc++
fails against SDK 27 (decided with Emmz on 2026-10-09; `docs/dependencies.md`).

- build: `zig build`
- test: `zig build test --summary all`
- format: `zig fmt --check src build.zig`
- lint: none — the Zig compiler already rejects unused variables and similar; no separate linter.
- eval (separate, not a core gate; needs the model and the real workspace): `cd <real-workspace> && devlog-index eval`

## Risks / Trade-offs

- [Model load per CLI invocation may exceed the 1 s budget] → Measured in the first section on the real workspace
  before building further; fallback is an optional persistent mode later, not a different interface.
- [llama.cpp throughput lower than Ollama's for a full rebuild] → Full rebuilds are rare; incremental
  updates embed only a few passages. Batch where the fork's API allows.
- [GGUF quantisation (Q5_K_M) ranks differently from the spike's f16 model] → Golden set re-run in the
  first sections; chunking thresholds tuned against it.
- [Zig 0.16 pre-1.0 churn; sqlite-vec pre-1.0] → Versions pinned; same toolchain as memlite, so breakage
  is met once for both.
- [Thread reference patterns miss informal wording] → Conservative by design (no false threads);
  the follow-up skill convention (reversing notes name the superseded file) makes new notes exact.
- [Pure paraphrases miss both methods] → Accepted; Claude reformulates in-session. Golden set records
  any such misses that matter.
- [Golden set holds client paths] → Lives in the workspace, outside this repo.

## Migration Plan

Not applicable: new tool, no existing data. Rollback is deleting the binary and `.devlog-index/`.

## Open Questions

- Exact passage-length threshold and per-method k: start at 80 words and k=5, tune against the golden set.
- Whether to also share memlite's model cache path (`~/.memlite/models/`) to avoid a second download —
  harmless either way.
