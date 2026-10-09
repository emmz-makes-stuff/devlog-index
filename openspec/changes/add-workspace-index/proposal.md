# Proposal

## Why

The emmz `devlog` skill records the *why* of every change (decisions and their reasons, rejected
alternatives, questions and answers, gate results, stops) as small append-only notes. Once a change is
archived, that reasoning is only reachable by grepping `openspec/changes/archive/`, one repo at a time, in
the exact words the note happened to use. In the first real workspace (five repos, ~600 notes) standards are
decided in one repo and applied in others, so neither Emmz nor Claude can reliably answer "why did we do
it that way?" or "what's the standard for X?" without re-asking or re-deciding.

## What Changes

- A new local CLI, `devlog-index`, that indexes a **declared workspace** of repos and answers
  plain-language questions with ranked passages and their sources.
- **Workspace config**: a JSON file at the workspace root naming the workspace and its member repos,
  found by walking up from the working directory, so a query from any member covers the whole workspace.
- **Indexing** (`update`): devlog notes from archived and active changes, change artifacts (proposal,
  design, tasks, spec deltas of active changes) and main specs; archived spec deltas and legacy
  `DEVLOG.md` files are excluded. Incremental by content hash; embeddings computed locally.
- **Query**: hybrid retrieval returning the union of lexical and semantic top results, each labelled with
  repo, change, date, kind, archived state and the method that found it; each matching note brings its
  **thread** (later notes in the same change that refer back to it). The tool returns passages; Claude
  writes answers.
- **Retrieval quality gate** (`eval`): a golden set of questions and expected sources, failing when an
  expected source falls out of the top 10.
- **Status** reporting index freshness, counts and model presence.
- Nothing leaves the machine; the only network use is the one-time inbound model download.

Out of scope (later changes): legacy `DEVLOG.md`, code→note navigation via blame and section base
commits, an "all my repos" workspace, and the `devlog`/`pickup` skill changes that will direct Claude to
run `update` at section done and at pickup.

## Capabilities

### New Capabilities
- `workspace-config`: declaring a workspace and its member repos, and resolving it from any directory
  inside a member.
- `corpus-indexing`: what is indexed and excluded, how it is chunked and classified, incremental update,
  model pinning, and status reporting.
- `workspace-query`: plain-language query, hybrid union retrieval, result labelling, thread expansion,
  graceful handling of an unbuilt index, and machine-readable output.
- `retrieval-eval`: the golden-set evaluation that gates retrieval quality.

### Modified Capabilities
<!-- None: greenfield project, no existing specs. -->

## Impact

- New Zig 0.16 codebase (ADR-0001) reusing memlite's vendored SQLite, sqlite-vec and llama.cpp binding.
- New local data per workspace: config, SQLite index and golden set at the workspace root (ADR-0002).
- New machine dependencies logged in `docs/dependencies.md` (zig 0.16, Xcode CLT); a ~99 MB embedding
  model cached on first update.
- No changes to the member repos themselves; read-only access to their `openspec/` trees.
- Enables a follow-up change in `emmz-dev-skills` (devlog/pickup skills).
