# Cold-query budget: met with ~10× headroom

<!-- Section: 2 · Tasks: 2.2 · Base: 8493c1d -->

`devlog-index bench-cold` (hidden) times one cold query as a fresh process: load the pinned GGUF, embed
one `search_query:` input, k=5 cosine search over 3,200 random unit 768-d vectors in a `vec0` table
(`bench-cold --setup <db>` builds that table, ~12.7 MB).

ReleaseFast (what `install.sh` will ship), five fresh processes, this machine, in the sandbox:

| run | model load | query embed | vector search | in-process | `time` real |
|---|---:|---:|---:|---:|---:|
| 1 | 66 ms | 15 ms | 4 ms | 85 ms | 0.09 s |
| 2–5 | 20 ms | 14 ms | 4–5 ms | 39–40 ms | 0.04 s |

Debug build: 60 ms in-process but 0.57 s real (unoptimised binary start-up) — still under budget, but
the budget is judged on ReleaseFast.

Run 1 is the page cache warming for the 99 MB model; a truly cold disk would add to the model load,
but there is ~10× headroom. The sandbox doesn't plausibly skew this downward, so no
outside-the-sandbox timing is needed for 2.2; 7.5 re-measures the real `query` on the real workspace.

Not measured here: FTS5 search and reading passage text — both milliseconds at this size.

Model file: `~/.devlog-index/models/nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q5_K_M.gguf`
was copied from memlite's cache (same pinned URL, byte-identical source) instead of downloaded, so the
download path (`download.ensureCached`) has not yet run for real. That happens in §5 (`update` on a
fresh machine) or can be checked by deleting the file.

## Next

- Design Open Question "share memlite's model cache?" stays open: for now each tool has its own copy.
