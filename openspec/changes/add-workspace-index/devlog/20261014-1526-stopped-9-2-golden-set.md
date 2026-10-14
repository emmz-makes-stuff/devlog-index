# Stopped at 9.2: the real workspace's golden set

<!-- Section: 9 · Tasks: 9.1 done, 9.2 blocked · Base: ea64da8 -->

9.1 is built, green and committed on its own as `feat(add-workspace-index): eval (9.1)`. Emmz chose that
over holding it for one §9 commit. Gates: `BUILD_EXIT:0`, `TEST_EXIT:0` (90/94 passed, 4
model-gated tests skipped), `FORMAT_EXIT:0`, `VALIDATE_EXIT:0`, `GATES_EXIT:0`.

## What blocks 9.2

9.2 seeds `~/github/oomi/nova/.devlog-index/golden.json` with the spike's five questions and their
expected sources. ADR-0004 records only their ranks: the questions and paths are client content and are
recorded nowhere in this repo. CLAUDE.md also lists seeding the real golden set as a stop-and-ask.
`~/github/oomi/nova` already has `devlog-index.json` and `.devlog-index/index.db`, but no `golden.json`.

**Question for Emmz:** what are the five questions and their expected source paths? Which one is the
paraphrase question?

Recipe (Emmz either pastes the questions and paths for me to write, or writes the file herself):

```sh
cat > ~/github/oomi/nova/.devlog-index/golden.json <<'JSON'
{"questions": [
  {"question": "<standard question, vocabulary mismatch>", "expected": ["<member>/openspec/..."]},
  {"question": "<same, in the spec's own words>",          "expected": ["<member>/openspec/..."]},
  {"question": "<paraphrase of a decision>",               "expected": ["<member>/openspec/..."], "known_miss": true},
  {"question": "<decision, in the note's own words>",      "expected": ["<member>/openspec/..."]},
  {"question": "<decision, specific technical terms>",     "expected": ["<member>/openspec/..."]}
]}
JSON
cd ~/github/oomi/nova && devlog-index update && devlog-index eval; echo "EVAL_EXIT:$?"
```

(Before §10's `install.sh`, use `~/github/emmz/devlog-index/zig-out/bin/devlog-index` instead of
`devlog-index`. Run it with the sandbox off, because the model cache is under `~/.devlog-index`.)

- **On PASS** (`EVAL_EXIT:0`): tick 9.2, write the section-9-done note, and commit 9.2 as the §9 commit.
- **On FAIL:** for each MISSED line, look at its per-method ranks and try the chunk threshold (80 words)
  and k (5) against it, per D7/D6. Record every miss that remains, with its reason, then stop and agree
  them with Emmz.

## 9.1 decisions (Emmz's answers, 2026-10-14)

These are also in `design.md` D10.
- `golden.json` is `{"questions": [{"question", "expected": [...], "known_miss": false}]}`. Paths are
  relative to the workspace root and unknown fields are rejected. Paths are matched as
  `resolve(root, expected)` against `files.path`, which is built as `resolve(root, member)/openspec/rel`.
- The verdict comes from the default top ten. A source outside it is shown with its rank in each method's
  own list, searched to depth 100. That prints `>100` when the list is full, or `no match` when the
  method's list ended before reaching the source.
- `eval` **fails** when semantic search can't run (`cannot evaluate: semantic search skipped: …`).

How it works:
- `query.rank` (new, public) returns both methods' id lists. `query.staleness` (new, public) is the
  freshness notice, split out so `eval` checks it once, not once per question. `query.run` now calls both
  and behaves the same as before.
- `eval` runs `rank` at k=100 and builds the primary results as `merge(lex[0..5], sem[0..5])`. That
  matches `query`'s default except for exact score ties at the k=5 boundary, which isn't worth a second
  pass.
- A source's rank is its best passage's rank. Verdicts: FOUND, MISSED, KNOWN MISS, UNEXPECTED, NOT
  INDEXED. Only MISSED and NOT INDEXED fail. A not-indexed source wins over every other verdict.
- `devlog-index eval` exits 1 on FAIL and 2 when given extra arguments. A stale-index notice goes to
  stderr and the run still grades.
- The tests use the stub embedder. The stable miss is `beta/.../20260320-1200-change-done.md` for
  "thundering-herd argument": no lexical match, semantic rank 33. If the fixture or the stub's hash
  changes, re-probe and update `beta_done` and the `semantic 33` assertions.

## Next

- Wait for Emmz's answer above, then do 9.2 from the recipe (On PASS / On FAIL).
- Still to do in 9.2: try thread expansion on the real workspace, to see whether real notes use reference
  forms D8 misses (from the section-8-done note).
- After §9: §10, task 10.1 (`install.sh` and README, which documents the `golden.json` format).
