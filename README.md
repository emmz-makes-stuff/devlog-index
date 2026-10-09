# devlog-index

A local, searchable index over OpenSpec history — devlog notes, change artifacts and specs — across a
declared workspace of repos. Ask a plain-language question; get ranked passages labelled with where they
came from. Nothing leaves the machine.

## Commands

- `devlog-index init <name> <member>…` — declare a workspace in the current directory.
- `devlog-index update [--rebuild]` — index the workspace (incremental by default).
- `devlog-index query [--json] [--k N] "<text>"` — ranked passages for a question.
- `devlog-index status [--json]` — index freshness, counts and model presence.
- `devlog-index eval` — check retrieval against the workspace's golden set.

## Building

Build through `make` (`make build`, `make test`, `make gates`), not bare `zig build`: on macOS it points
Zig at the SDK 26 headers. See `docs/dependencies.md`.
