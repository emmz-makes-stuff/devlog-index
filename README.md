# devlog-index

A local, searchable index over OpenSpec history — devlog notes, change artifacts and specs — across a
declared workspace of repos. Ask a plain-language question; get ranked passages labelled with where they
came from. Nothing leaves the machine.

## Install

```sh
./install.sh
```

This builds a ReleaseFast binary (through `make release`) and copies it to `~/.local/bin/devlog-index`
(`PREFIX=/some/dir ./install.sh` installs to `/some/dir/bin`). It warns if that directory is not on
`PATH`. Building needs the tools in `docs/dependencies.md`.

## Workspaces

A workspace is a folder holding the repos you want searched together. Declare it once, from that folder:

```sh
cd ~/github/acme
devlog-index init acme api infra web
```

This writes `devlog-index.json` (`{"name": "acme", "members": ["api", "infra", "web"]}`). Members are
paths relative to the workspace folder. Every other command finds the workspace by walking up from the
current directory, so it works from inside any member repo; the nearest `devlog-index.json` wins.

Only declared members are indexed. In each member, these are indexed: `openspec/changes/*/devlog/*.md`
notes, each change's `proposal.md`, `design.md`, `tasks.md` and spec deltas (archived changes included,
except archived spec deltas), and the main specs under `openspec/specs/`. A legacy `DEVLOG.md` is not indexed.

## Commands

### `devlog-index update [--rebuild]`

Indexes the workspace. It is incremental: only files whose content changed are re-read, and only
passages whose text changed are re-embedded. `--rebuild` starts the index again from nothing, which is
needed when the embedding model changes. An interrupted update leaves the previous index intact.

The first update downloads the embedding model (nomic-embed-text v1.5, Q5_K_M GGUF, from Hugging Face)
to `~/.devlog-index/models/`. After that, everything runs offline.

### `devlog-index query [--json] [--k N] "<text>"`

Ranks passages two ways, by keywords (BM25) and by meaning (embeddings), and returns the union of each
method's top `N` (default 5, so at most 10 results). Each result is labelled with its member, change
(or "main spec" and capability), whether the change is archived or active, the kind of file (`decision`,
`stopped`, `section`, `answer`, `change`, `review` or `note` for devlog notes; `proposal`, `design`,
`tasks`, `spec` or `spec-delta` otherwise), the note's time, the path, and which method found it.

A devlog-note result also shows its **thread**: later notes in the same change that refer back to it,
by filename, by its `HHMM` time next to "note" ("the 1015 note"), or, for a `section-N-done` note, by
`§N-done` or "section N done". Each thread entry holds only the passages that make the reference.

When semantic search can't run (no model, a model the index wasn't built with), the results are
keyword-only and a notice says why. When files have changed since the last update, a notice counts
them. Notices go to stderr, and onto every `--json` result.

### `devlog-index status [--json]`

Shows the workspace root, the index path, each member's state and passage count, how many files have
changed since the last update, when that was, and whether the model is downloaded.

### `devlog-index eval`

Checks retrieval against the workspace's golden set (below). Each question is run as a default query.
A question passes when every expected source is in the top ten. A source outside the top ten is shown
with its rank in each method's own list, searched to depth 100. `eval` exits 1 when any question fails
or any expected source is not in the index, and when semantic search can't run.

## `--json` output

With `--json`, stdout holds only JSON, one object per line; everything else goes to stderr.

`query --json` writes one object per result:

```json
{"member": "api", "change": "add-retry", "capability": null, "state": "archived",
 "kind": "decision", "note_time": "2026-03-10 10:15", "path": "/…/api/openspec/changes/archive/…/devlog/20260310-1015-decision-retry-policy.md",
 "rel": "openspec/changes/archive/…/devlog/20260310-1015-decision-retry-policy.md",
 "methods": ["lexical", "semantic"], "text": "…",
 "thread": [{"path": "/…", "kind": "section", "note_time": "2026-03-11 14:00", "text": "…"}],
 "notices": []}
```

(Shown wrapped; each object is on one line.) `change` is null for a main spec, `capability` is null
outside specs, and `note_time` is null for anything but a devlog note.

`status --json` writes one object:

```json
{"workspace": "acme", "root": "/…/acme", "index": "/…/acme/.devlog-index/index.db", "indexed": true,
 "members": [{"name": "api", "path": "/…/acme/api", "status": "ok", "passages": 412}],
 "files_changed": 0, "last_update": "2026-10-14T14:40:18Z",
 "model": {"cached": true, "path": "/…/.devlog-index/models/…"}}
```

A member's `status` is `ok`, `missing` or `no_openspec`.

## Where data lives

- `<workspace>/devlog-index.json` — the workspace config.
- `<workspace>/.devlog-index/index.db` — the index (SQLite with FTS5 and sqlite-vec).
- `<workspace>/.devlog-index/golden.json` — the golden set for `eval`, if you write one.
- `~/.devlog-index/models/` — the embedding model, shared by every workspace.

The workspace folder is usually not a repo itself. If it is, add `.devlog-index/` to its ignores.

### The golden set

```json
{"questions": [
  {"question": "why is the schema private?", "expected": ["api/openspec/changes/archive/…/devlog/…-decision-schema.md"]},
  {"question": "how long to pause when auth hiccups", "expected": ["api/openspec/…"], "known_miss": true}
]}
```

Paths are relative to the workspace folder. A question marked `known_miss` is reported but does not
fail `eval`; when all its sources reach the top ten, `eval` says so, so the mark can be removed. Unknown
fields are rejected.

## Exit codes

0 on success; 1 on an error (the message names what to do, e.g. `run: devlog-index update`) or a failed
`eval`; 2 on a usage error.

## Building

Build through `make` (`make build`, `make test`, `make gates`), not bare `zig build`: on macOS it points
Zig at the SDK 26 headers. See `docs/dependencies.md`.
