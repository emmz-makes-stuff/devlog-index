# Design

## Context

ADR-0003 fixed the interface as a CLI and put discoverability on `--help` and "the calling skills". The CLI
surface is `init`, `update`, `query`, `status`, `eval` (see `README.md`). The agent-facing parts are `query`,
`status` and `update`; `--json` gives one object per line on stdout, with notices on stderr and in each
result's `notices`. See proposal.md for scope.

## Goals / Non-Goals

**Goals:**
- One skill an agent can follow cold to get a correct, honestly-labelled answer from the index.
- Distribution that needs only `/plugin marketplace add` and `/plugin install`.

**Non-Goals:**
- Shipping or building the binary from the plugin.
- Covering `init`, `eval`, or the golden set; those are for the human.
- Any CLI change, including a `--help` rewrite.

## Decisions

**Layout: marketplace at the repo root, plugin in a subdirectory.**

```
.claude-plugin/marketplace.json            lists one plugin, source "./plugins/devlog-index"
plugins/devlog-index/.claude-plugin/plugin.json
plugins/devlog-index/skills/query-devlog-index/SKILL.md
```

The repo root is the Zig project, so the plugin cannot be the root without its manifest and `skills/`
mixing into the build tree. A relative `source` keeps the marketplace self-contained: one `git clone` serves
both. Alternative: a separate marketplace repo. Rejected: two repos to keep in step for one skill.

**One skill, not one per command.** `query`, `status` and `update` are one workflow (check, refresh, ask).
Splitting them would make the agent load three skills for one question. The skill is a single `SKILL.md`
with no scripts; everything it does is a shell command the agent already can run.

**Skill name `query-devlog-index`.** Verb first, names the tool, and leaves room for a sibling skill (for
example one that writes notes) without renaming.

**The skill assumes the binary and fails closed.** The plugin does not install `devlog-index`: that needs
Zig, the SDK 26 workaround and a model download (`docs/dependencies.md`), which an agent must not improvise.
If `devlog-index` is not on `PATH`, the skill says to tell the user to run `./install.sh` from the repo, and
stop. This is also why the binary is not bundled in the plugin: it is a ReleaseFast native build for one
platform.

**Status before query, always.** `status --json` is cheap and the only way to learn that the index is
missing or stale before trusting results. The query's own stale-index notice would catch the second case
too, but one extra call at the start of a task is cheaper than answering from stale text. The skill makes
it once per task, not once per query.

**Honest degraded results.** The spec forbids presenting degraded results as complete; the skill turns that
into explicit agent behaviour: report keyword-only results as such, report "nothing found" as such, never
fill the gap from memory.

**Staying in step with the CLI.** Drift is a real risk because the skill restates the README. Mitigation is
procedural, not a new gate: the skill links nothing, restates only flags and notices that the README and the
`workspace-query` spec already promise, and the section's self-review step checks it against both. A
generated or tested skill would need a new tool; not worth it for one file.

**Validation by the Claude Code validator, run by hand.** `claude plugin validate` checks both manifests
and the skill frontmatter. It is run manually in the section and its output quoted in the devlog note. It is
not added to `make gates`: that would put the Claude Code CLI into `docs/dependencies.md` and `make deps`
for a check that rarely changes. If Emmz wants it as a gate, that is a small follow-up.

## Risks / Trade-offs

- [Skill drifts from the CLI] → review against README and spec in the section self-review; the spec's
  "stays in step" requirement makes it a stated acceptance check.
- [Agent uses the skill without the binary installed] → the skill's first instruction is to check
  `command -v devlog-index` and stop with a message if absent.
- [Agent runs `update` and triggers a model download unexpectedly] → the skill states the first-run cost, and
  `update` is run only when `status` shows it is needed.
- [Manifest schema changes in Claude Code] → the validator run catches it at build time; nothing in the CLI
  depends on the manifests.

## Confirmed with Emmz

- No gate for `claude plugin validate`; manual check only.
- Marketplace `devlog-index`, plugin `devlog-index`, owner Emmz, version `0.1.0`.
- Drift protection is procedural (section self-review plus a README note), with no automated check.
