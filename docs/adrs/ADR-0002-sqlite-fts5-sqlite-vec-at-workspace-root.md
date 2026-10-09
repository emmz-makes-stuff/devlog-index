# ADR-0002 — SQLite + FTS5 + sqlite-vec, stored at the workspace root

- **Status:** Accepted
- **Date:** 2026-10-09
- **Change:** `add-workspace-index`
- **Deciders:** Emmz, Claude

## Context

The first real workspace (five repos) yields ~3,200 chunks × 768-dimension vectors (~10 MB) plus text.
Exhaustive scoring in memory takes milliseconds, so no approximate-nearest-neighbour index is needed. But
a full embed costs ~50 s (measured), so embeddings must persist, and updates must be incremental: each
source file's content hash and the chunks derived from it must be tracked.

Unlike Emmz's `devlog` (ADR-0002 there: no database, ~240 KB rebuilt per call in 0.31 ms), the expensive
derived data here — embeddings — makes rebuild-per-call impossible.

A workspace is a **declared** set of repos (discovery decision); the first real workspace's folder is not itself
a git repo.

## Decision

- Store the index in **one SQLite database** with **FTS5** for BM25 and **sqlite-vec** for vectors,
  reusing memlite's vendored amalgamations and adapting its schema.
- Pin the embedding model URL and dimension in a `settings` table; a mismatch refuses to run until a
  deliberate full rebuild (memlite's `MODEL_MISMATCH` pattern).
- The **workspace config** (JSON: name + member repo paths) lives at the workspace root; the tool finds it
  by **walking up from the working directory**, nearest config wins. The **index database** lives beside
  it, as does the workspace's golden query set.

## Consequences

- Incremental update is a hash comparison per file; a section's new notes embed in under a second.
- The index is derived data: losing it costs one full rebuild, never information.
- Config and index are machine-local by construction for the first real workspace (its root isn't a repo).
- "All my repos" later is a config higher up (e.g. `~/github/`), with no redesign.
- sqlite-vec is pre-1.0; the vendored version is pinned.

## Alternatives considered

**Vectors as BLOBs with hand-written brute-force cosine.** Rejected: re-implements what sqlite-vec does
(brute force underneath) for no gain at this size.

**Flat files + in-memory BM25 (`devlog` style).** Rejected: incremental bookkeeping and BM25 written by
hand, with no binary-size saving once llama.cpp is linked.

**Index in a per-user location keyed by workspace** (`~/.devlog-index/<name>`). Rejected: walking up to a
config beside the index keeps discovery and storage in one obvious place.
