# agent-query-skill Specification

## Purpose

Gives agents what they need to query a workspace's devlog index through the CLI correctly, and gives people a
way to install it, as a Claude Code plugin skill distributed through this repo acting as a plugin marketplace.

## Requirements

### Requirement: Marketplace distribution
The repo SHALL be a Claude Code plugin marketplace that lists one plugin, which contains the query skill.
Adding the marketplace and installing the plugin SHALL make the skill available to the agent.

#### Scenario: Marketplace validates
- **WHEN** the marketplace manifest and the plugin manifest are validated with Claude Code's plugin validator
- **THEN** both pass with no errors

#### Scenario: Install from the repo
- **WHEN** a user adds this repo as a marketplace and installs the listed plugin
- **THEN** the `query-devlog-index` skill appears in the agent's available skills

#### Scenario: Installing the skill does not install the binary
- **WHEN** the plugin is installed on a machine without `devlog-index` on `PATH`
- **THEN** the install succeeds, and the skill itself tells the agent to report the missing binary rather than try to build or install it

### Requirement: Skill triggers on history questions
The skill's description SHALL name the situations it applies to: finding past decisions, reasons, standards
or history recorded in OpenSpec devlog notes, change artifacts and specs across a workspace of repos.

#### Scenario: Question about a past decision
- **WHEN** the agent is asked why something was decided, or what an earlier change settled
- **THEN** the skill's description matches the situation

#### Scenario: Unrelated question
- **WHEN** the agent is asked about the current code only, with no question about history or decisions
- **THEN** the skill's description does not claim the situation

### Requirement: Querying guidance
The skill SHALL tell the agent to run `devlog-index query --json "<text>"`, to phrase the text as a plain
language question or distinctive terms, to widen results with `--k N`, and to read the JSON one object per
line from stdout only.

#### Scenario: Command form
- **WHEN** the agent follows the skill to answer a question about history
- **THEN** the command it runs is a `devlog-index query` with `--json` and the question as one quoted argument

#### Scenario: Reading a result
- **WHEN** the skill explains a result
- **THEN** it names the labels (member, change or main spec, state, kind, note time, path, finding methods) and says which of them tell a decision from a note about progress

#### Scenario: Reading threads
- **WHEN** a result carries thread entries
- **THEN** the skill tells the agent that later notes may reverse or refine the result, and that it must read the thread before relying on the result

### Requirement: Freshness guidance
The skill SHALL tell the agent to check `devlog-index status --json` before relying on query results, and to
run `devlog-index update` when the index is missing or files have changed since the last update.

#### Scenario: Stale index
- **WHEN** `status` reports files changed since the last update
- **THEN** the skill directs the agent to run `update` before querying, or to tell the user the results may be stale

#### Scenario: Update cost is stated
- **WHEN** the skill describes `update`
- **THEN** it says the first run downloads the embedding model and may take longer, and that later runs are incremental

### Requirement: Failure handling guidance
The skill SHALL tell the agent how to treat each failure it can meet, and SHALL NOT let it present degraded
results as complete.

#### Scenario: Keyword-only results
- **WHEN** a result's notices say semantic search was skipped
- **THEN** the skill directs the agent to tell the user the results are keyword-only and why, and to retry with distinctive terms rather than a paraphrase

#### Scenario: Missing index or workspace
- **WHEN** a command exits 1 saying the index is missing or no workspace is found
- **THEN** the skill directs the agent to run `update` if a workspace exists, and otherwise to stop and tell the user, who declares workspaces; the agent does not run `init`

#### Scenario: Exit codes
- **WHEN** the skill lists exit codes
- **THEN** it gives 0 for success, 1 for an error whose message says what to do, and 2 for a usage error

#### Scenario: No results
- **WHEN** a query returns no passage that answers the question
- **THEN** the skill directs the agent to say so, and not to answer from memory as though the index had confirmed it

### Requirement: Skill stays in step with the CLI
Every command, flag, notice and exit code the skill names SHALL exist in the CLI's documented behaviour.

#### Scenario: Skill matches the README
- **WHEN** the skill is reviewed against `README.md` and the `workspace-query` spec
- **THEN** no command, flag or exit code in the skill is absent from them, and none contradicts them
