# Proposal

## Why

ADR-0003 chose a CLI over MCP, so agents reach `devlog-index` through the shell, and "discoverability rests
on `--help` and the calling skills". No skill exists yet. An agent that has never seen the tool has to guess
its flags, may not know to check freshness, and will misread a keyword-only result as a full one. A skill
fixes that at no context cost until it is used.

## What Changes

- Add a Claude Code **plugin marketplace** at the repo root (`.claude-plugin/marketplace.json`) listing one
  plugin, so Emmz or anyone else adds it with `/plugin marketplace add` and installs it with
  `/plugin install`.
- Add the plugin (`plugins/devlog-index/`) containing one skill, `query-devlog-index`, which teaches an
  agent to:
  - **query**: when to use the tool, how to phrase a query, `--json` and `--k`, and how to read result
    labels, the found-by method and thread entries;
  - **check freshness**: `status` first, `update` when files have changed or the index is missing;
  - **handle failure**: keyword-only notices, a missing index or model, and what exit codes 0, 1 and 2 mean.
- Document the marketplace install in `README.md`.
- Out of scope: workspace setup (`init`; left to the human), changing the CLI, and installing the binary
  through the plugin or `install.sh`. The skill assumes `devlog-index` is already on `PATH` and says what to
  do when it is not.

## Capabilities

### New Capabilities
- `agent-query-skill`: the marketplace and plugin that ship the skill, and what the skill must tell an
  agent about querying, freshness and failure handling.

### Modified Capabilities

None. The CLI's behaviour does not change; the skill describes it.

## Impact

- New files only: `.claude-plugin/marketplace.json`, `plugins/devlog-index/.claude-plugin/plugin.json`,
  `plugins/devlog-index/skills/query-devlog-index/SKILL.md`, plus a `README.md` section.
- No change to `src/`, the build, or `install.sh`.
- The skill restates CLI behaviour from `README.md` and the `workspace-query` spec, so it can drift from
  them. The design says how that is kept in check.
- Possible new dependency: the Claude Code CLI, for `claude plugin validate`. The design decides whether
  that becomes a gate (and so a `docs/dependencies.md` row) or stays a manual check.
