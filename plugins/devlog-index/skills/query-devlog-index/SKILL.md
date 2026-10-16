---
name: query-devlog-index
description: Use when you need to find why something was decided, what an earlier change settled, or what a standard or spec says, recorded in OpenSpec devlog notes, change proposals, designs, tasks and specs across a workspace of repos. Searches a local index with the devlog-index CLI. Do not use for questions about what the current code does.
---

# Query the devlog index

`devlog-index` is a local search over OpenSpec history: devlog notes, change artifacts and specs, across a
declared workspace of repos. It returns ranked passages, each labelled with where it came from. Use it to
recover past decisions and their reasons before you decide or recommend something that history may already
have settled. Nothing leaves the machine.

## 1. Check the tool and the index (once per task)

```sh
command -v devlog-index
devlog-index status --json
```

- If `devlog-index` is not on `PATH`, stop and tell the user to run `./install.sh` in the devlog-index repo.
  Do not try to build or install it yourself.
- `status --json` prints one object. Read these fields:
  - `indexed`: `false` means no index yet.
  - `files_changed`: more than 0 means files changed since the last update.
  - `model.cached`: `false` means semantic search cannot run until `update` downloads the model.
  - `members[].status`: `ok`, `missing` or `no_openspec`. Anything but `ok` means that member has nothing
    indexed; tell the user.
- If `indexed` is `false` or `files_changed` is above 0, run:

```sh
devlog-index update
```

  It is incremental, so later runs are quick. The first run downloads the embedding model (about 99 MB) and
  takes longer. Run `update` only when `status` says it is needed.

If `status` exits 1 with "no workspace found", the user has not declared a workspace here. Tell them. Do not
run `init`: choosing which repos belong together is theirs to decide.

## 2. Query

```sh
devlog-index query --json "why is the schema private"
devlog-index query --json --k 10 "retry policy for auth failures"
```

- Quote the question as one argument. Use a plain-language question, or a few distinctive terms (a name, a
  flag, a phrase that would appear verbatim). If a paraphrase finds nothing, try the exact term.
- `--k N` sets how many results each method returns (default 5). The output holds the union of the lexical
  and semantic top N, so up to 2N results. Raise it when the first results look close but not right.
- With `--json`, stdout holds only JSON, one object per line. Notices go to stderr and are repeated in each
  object's `notices`. Run from anywhere inside a member repo or the workspace folder.

### Reading a result

Each object has: `member`, `change` (null for a main spec), `capability` (specs only), `state` (`active` or
`archived`), `kind`, `note_time` (devlog notes only), `path`, `rel`, `methods`, `text`, `thread`, `notices`.

- `kind` tells you what the passage is. For devlog notes, `decision` records a choice and why, `answer`
  records what the user said, `stopped` records a blocker and its question, `review` and `change` record
  review outcomes and whole-change summaries, `section` records progress, and `note` is anything else. Prefer
  `decision` and `answer` when you want a settled choice. `proposal`, `design`, `tasks`, `spec` and
  `spec-delta` come from change artifacts and specs.
- A `spec` with `change: null` is a main spec: the standing requirement. Archived change material is history
  of how it got there. When they differ, say so rather than choosing silently.
- `methods` says how it was found: `lexical` (keywords), `semantic` (meaning), or both. A result found by
  both is the strongest.
- `path` is the file. Read the file when the passage is cut off or you need the surrounding context.
- Results are passages, not files: the same file can appear more than once, as different passages or found by
  different methods. Group by `rel` before you count sources.

### Read the thread before you rely on a result

A devlog-note result carries `thread`: later notes in the same change that refer back to it. A later note may
reverse or refine the result. Read every thread entry before you quote the result as the current position,
and say when a later note changed it. The tool does not hide or demote superseded results.

## 3. When things go wrong

Never present degraded results as complete.

- **Keyword-only results.** A notice says semantic search was skipped, and why (no model, or a model the
  index was not built with). Tell the user the results are keyword-only and give the reason. Retry with
  distinctive terms rather than a paraphrase. If the cause is a missing model, `update` fixes it.
  If the index was built with a different model, tell the user: it needs `update --rebuild`.
- **Stale index.** A notice counts files changed since the last update. Run `update` and query again, or tell
  the user the results may be stale.
- **Index missing.** The command exits 1 and names `update`. Run it if a workspace exists.
- **"cannot read …/index.db; rebuild it with: devlog-index update --rebuild".** This can be a real corrupt
  or incompatible index, but it is also what a sandbox that forbids writes to the workspace folder looks
  like, because opening the index needs to write a lock. Do not rebuild on first sight: that deletes the
  index. If your shell is sandboxed, retry the same command once with the sandbox lifted (only for a
  workspace the user pointed you at). Rebuild only if it still fails, and tell the user first.
- **No workspace.** Exit 1, "no workspace found". Tell the user. Do not run `init`.
- **No answer in the results.** Say so. Do not answer from memory as though the index had confirmed it, and do
  not stretch a weak match into a decision.

Exit codes: `0` success; `1` an error, whose message says what to do (for example `run: devlog-index
update`); `2` a usage error, so check the command line against this page.

Read the stderr message before retrying. Do not loop on a failing command.
