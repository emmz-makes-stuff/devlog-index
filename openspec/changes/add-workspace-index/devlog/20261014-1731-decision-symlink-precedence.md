# Decision: real folders win over symlinked ones (§15)

<!-- Section: 15 · Base: 2d4f27d -->

A side agent found a flaw in §14.2's `sources.Walk`, and I confirmed it in the code.

- `visited` keeps the real paths of folders already walked. Entries are walked in name order, so
  whichever path reaches a real folder **first** claims it.
- If `specs/alias` → `specs/auth`, then "alias" sorts first. The specs are indexed under capability
  `alias`, and the real `auth` is skipped.
- The same happens across folders. A link under `changes/` into `specs/` wins, because "changes" sorts
  before "specs".
- The §14 test missed this because both of its links pointed outside the tree.

## Agreed with Emmz (2026-10-14)

- **Two-pass walk.**
  - Pass 1 walks every member's real folders without following symlinked folders. It marks each real
    folder as visited and queues every symlinked folder (absolute link path plus `rel`).
  - Pass 2 follows the queue in path order. It skips a target that was already visited, and it queues
    any links found inside the targets it follows.
  - Symlinked **files** can still be handled in place, because they don't claim a folder.
- Emmz turned down the per-folder ordering option, because it leaves the cross-folder case broken.
- **Build after a restart.** Emmz is restarting `claude`, so §15 is built from this note.

## Next

- §15, task 15.1 in `src/sources.zig`.
  - In `Walk.dir`, a `.sym_link` whose `stat` gives `.directory` goes on a `pending` list, in place of
    the recursive call.
  - `discover` walks all members first, then drains `pending`, sorted by path, until it is empty.
  - Note that `Walk.member` and `openspec` vary per member, so each pending entry needs its own
    `member`/`openspec`.
- New test: add `specs/alias` → `specs/auth` (sibling link) and
  `changes/add-cache/specs/linked` → `specs/auth`. The second one is a spec delta, and the
  classification path matters. Expect `auth/spec.md` only under `openspec/specs/auth/spec.md`, with no
  `alias` and no extra delta.
- Then do the change-done review (`git diff f032e0c..HEAD`), write the note, and offer
  `/opsx:archive`.
