# ADR-0004 — Hybrid retrieval: union of BM25 and vector top results

- **Status:** Accepted
- **Date:** 2026-10-09
- **Change:** `add-workspace-index`
- **Deciders:** Emmz, Claude

## Context

Success means the note holding the decision ranks near the top for plain-language questions, asked by
Emmz or by Claude. A throwaway spike on 2026-10-09 measured this against the first real workspace (five
repos, ~600 devlog notes, ~270k words), using known answers for five real questions. The questions and
paths are client work and are not recorded here; only the ranks are.

Spike v1 (notes embedded whole; archived spec deltas included):

| Question shape                               | BM25 | vector | RRF (k=60) |
|----------------------------------------------|-----:|-------:|-----------:|
| standard question, vocabulary mismatch       | #127 |     #5 |        #28 |
| same, in the spec's own words                |   #9 |     #2 |         #2 |
| paraphrase of a decision                     |  #60 |   #118 |        #60 |
| decision, in the note's own words            |   #1 |     #9 |         #3 |
| decision, specific technical terms           |   #4 |   #274 |        #27 |

Spike v2 (archived spec deltas excluded; notes chunked by paragraph with title prefix; specs split per
requirement):

| Question shape                               | BM25 | vector | RRF | in either top 5 |
|----------------------------------------------|-----:|-------:|----:|:---------------:|
| standard question, vocabulary mismatch       | #113 |     #3 | #20 | yes             |
| same, in the spec's own words                |   #5 |     #1 |  #1 | yes             |
| paraphrase of a decision                     | #308 |    #41 | #73 | no              |
| decision, in the note's own words            |   #1 |     #1 |  #1 | yes             |
| decision, specific technical terms           |   #2 |    #55 | #11 | yes             |

Costs: 3,222 chunks; full embed ~48 s; query ~50 ms warm (via Ollama, same model family as ADR-0001).

## Decision

- **Retrieve with both** BM25 (FTS5) and vector similarity, and return the **union of each method's top
  results** (default five each), deduplicated, each labelled with the method(s) that found it.
- **Chunking rules:** devlog notes split into paragraph chunks (~80+ words) prefixed with the note's
  title; specs split per requirement; other artifacts split on `##`.
- **Exclude archived spec deltas** — they were merged into the main specs at archive and only duplicate
  them.
- **Each matching note brings its thread**: later notes in the same change that refer back to it (by
  filename, by time such as "the 1346 note", or by section such as "§7-done").
- **Retrieval quality is gated**: a golden set of question → expected-source pairs; `eval` fails if any
  expected source falls outside the top 10. The workspace's real golden set lives beside its index (not
  in this repo); the repo's tests use a synthetic fixture workspace.

## Consequences

- Concept questions (vector) and exact-term questions (BM25) both reach the top 10.
- Pure paraphrases with no shared vocabulary can still miss; through a session, Claude reformulates and
  re-queries. Directly, it is a known limit.
- Ranking changes are measured against the golden set, not judged by eye.

## Alternatives considered

**BM25 only (Emmz's `devlog` precedent).** Ranked the standard question at #113–#127. Rejected.

**Vector only.** Ranked a decision with specific terms at #55–#274. Rejected.

**Reciprocal Rank Fusion (memlite's method).** Averaging a #1 with a #300 buries answers only one method
finds (#20, #11, #27 above). Rejected.

**Auto-adjudicating which decision is current.** Rejected in exploration: it risks hiding the right
answer. Threads plus labels are shown instead.
