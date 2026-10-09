# Fixture workspace

A synthetic workspace for devlog-index's tests (design D10). Integration tests run against a temp copy,
so tests may add, change, move or delete files freely. Everything here is made up. `*-MARKER` strings
mark text that must never be indexed, so a test can grep for them in passages.

`devlog-index.json` declares two members, `alpha` and `beta`. These are the scenarios each file covers:

| Scenario | Files |
| --- | --- |
| Undeclared sibling repo is ignored | `scratch/` has an `openspec/` (a spec and a devlog note), but it isn't declared. `UNDECLARED-SIBLING-MARKER` |
| Files outside indexed paths | `alpha/README.md`, `alpha/openspec/project.md`, and this README |
| Main spec, split per requirement | `alpha/openspec/specs/auth/spec.md` (Purpose and three requirements), `beta/openspec/specs/api/spec.md` |
| Archived spec delta excluded | `alpha/…/archive/2026-03-10-add-retry/specs/auth/spec.md`: the same `auth` capability as the main spec. `ARCHIVED-DELTA-MARKER` |
| Active spec delta included | `alpha/openspec/changes/add-cache/specs/cache/spec.md`. `ACTIVE-DELTA-MARKER` |
| Legacy devlog excluded | `alpha/…/archive/2026-03-10-add-retry/DEVLOG.md`. `LEGACY-DEVLOG-MARKER` |
| Archived change name has its date prefix stripped | `archive/2026-03-10-add-retry` → change `add-retry`; `archive/2026-03-20-init-api` → `init-api` |
| Artifacts per `##` section | `add-retry/proposal.md` (has an intro before its first `##`), `add-retry/design.md` (has an empty section), `add-retry/tasks.md`, `init-api/proposal.md` (no title) |
| Long note split, title on every passage | `add-retry/devlog/20260310-1015-decision-retry-policy.md`: "Decision: retry policy", about 300 words |
| Note kinds from the filename slug | `section-1-start`, `decision-…`, `section-1-done`, `stopped-2-1-…`, `answer-…`, `review-…`, `change-done` |
| Reversal thread, filename reference | `20260313-1030-decision-retry-reversal` cites `20260310-1015-decision-retry-policy` (without `.md`). `20260314-0900-review-section-1` cites `…-retry-reversal.md` (with `.md`) |
| Thread by `HHMM` time next to "note" | `20260312-1100-answer-credentials` refers to "the 0915 note" (`20260312-0915-stopped-…`) |
| Thread by section done | `20260314-0900-review-section-1` refers to "§1-done" and "Section 1 done" (`20260311-1400-section-1-done`) |
| Earlier notes never thread | `20260310-0900-section-1-start` mentions "the 1015 note" but comes before it |
| No threading across changes | `beta/…/2026-03-20-init-api/devlog/20260320-1200-change-done` mentions "the 1015 note" and `20260310-1015-decision-retry-policy`, but in another change |
| Active change devlog | `alpha/openspec/changes/add-cache/devlog/20260401-1000-decision-cache-ttl.md` |

The indexed files, which is what discovery must return (19: alpha 15, beta 4):

- alpha: `specs/auth/spec.md`; `changes/add-cache/{proposal.md, tasks.md, specs/cache/spec.md,
  devlog/20260401-1000-decision-cache-ttl.md}`; `changes/archive/2026-03-10-add-retry/{proposal.md,
  design.md, tasks.md}` plus its seven devlog notes.
- beta: `specs/api/spec.md`; `changes/archive/2026-03-20-init-api/{proposal.md}` plus its two devlog
  notes.
