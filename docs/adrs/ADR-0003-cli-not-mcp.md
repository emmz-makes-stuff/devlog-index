# ADR-0003 — A CLI, not an MCP server

- **Status:** Accepted
- **Date:** 2026-10-09
- **Change:** `add-workspace-index`
- **Deciders:** Emmz, Claude

## Context

Two consumers, equally: Emmz querying from a terminal, and Claude retrieving past decisions mid-session.
A follow-up change to the emmz `devlog`/`pickup` skills will direct Claude to run the update at section
done and at pickup. Emmz's `devlog` faced the same choice (its ADR-0003) and chose a CLI; `memlite` chose
MCP to serve hosts without shell access.

## Decision

Ship a **CLI**: `init`, `update`, `query "<text>"`, `status`, `eval`. Human-readable output by default;
`--json` emits one object per line for agents.

## Consequences

- Emmz uses it directly; Claude reaches it through the shell and the skills' instructions, with no
  per-project MCP configuration.
- No context cost until used, unlike MCP tool schemas present in every session.
- Each invocation loads the GGUF (ADR-0001). Budget: a cold query under 1 s on the first real workspace. Missing it is solved
  by an optional persistent mode later, not by changing the interface.
- Discoverability rests on `--help` and the calling skills, so the command surface stays small.

## Alternatives considered

**MCP stdio server (the memlite pattern).** Keeps the model warm between calls, with typed tool schemas.
Rejected for v1: permanent context cost, per-project configuration, and no benefit for the terminal use.
An MCP surface can be added over the same core later.
