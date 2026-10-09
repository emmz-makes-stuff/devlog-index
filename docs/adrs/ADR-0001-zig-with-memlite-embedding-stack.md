# ADR-0001 — Zig 0.16, reusing memlite's embedding stack

- **Status:** Accepted
- **Date:** 2026-10-09
- **Change:** `add-workspace-index`
- **Deciders:** Emmz, Claude

## Context

`devlog-index` must embed text locally (hard constraint: indexed content never leaves the machine), update
incrementally in seconds, and answer queries well under a second. It is called a handful of times per
session — at pickup, at section done, and on demand — not in a tight agent loop.

Emmz's `memlite` already solves local embeddings: Zig 0.16 statically linking vendored SQLite 3.53.1,
sqlite-vec 0.1.9 (with a musl patch) and llama.cpp via the `daemonicai/llama.cpp.zig` fork, loading
`nomic-embed-text-v1.5` Q5_K_M (~99 MB GGUF) into a 6.4 MB binary. The retrieval spike (ADR-0004) used
the same model family through Ollama.

Emmz's standing default for back-end work is .NET 10, so this is a deliberate departure.

## Decision

Implement `devlog-index` in **Zig 0.16**, reusing memlite's vendoring, llama.cpp binding and model
download/lifecycle, with embeddings computed **in-process**.

## Consequences

- No daemon: the tool works whenever the binary and model file are present.
- The vendored sources, patches and build pattern are proven and can be followed, not rediscovered.
- Zig is pre-1.0; its build API breaks between releases. This is ongoing maintenance cost, already known
  from memlite.
- The CLI loads the GGUF on every invocation (ADR-0003). A cold query must stay under 1 s on the first real
  workspace; this is checked first in the build.
- The first `zig build` fetches the llama.cpp fork from GitHub; llama.cpp links Accelerate/Metal, so the
  macOS SDK is required.
- memlite's RRF fusion is **not** reused — see ADR-0004.

## Alternatives considered

**.NET 10 CLI + Ollama over HTTP** (Claude's recommendation). House default, least integration work,
measured in the spike. Rejected by Emmz: it depends on the Ollama daemon running, and memlite already
provides the in-process engine.

**.NET 10 + in-process ONNX Runtime.** No daemon, but native ONNX libraries, tokenizer edge cases and a
model the spike didn't test. Rejected: the Zig path removes the daemon with an engine already proven.

**TypeScript/Bun + Ollama.** A second runtime with no advantage over the .NET option. Rejected.
