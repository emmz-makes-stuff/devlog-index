# Tasks

## 1. Marketplace and plugin scaffold

- [x] 1.1 Add `.claude-plugin/marketplace.json` (name, owner, one plugin with relative `source` `./plugins/devlog-index`) and verify it parses with `jq .`
- [x] 1.2 Add `plugins/devlog-index/.claude-plugin/plugin.json` (name, description, version) and verify it parses with `jq .`
- [x] 1.3 Add a placeholder `plugins/devlog-index/skills/query-devlog-index/SKILL.md` with valid frontmatter (`name`, `description`) and verify `claude plugin validate .` passes, quoting its output in the devlog note

## 2. The skill

- [x] 2.1 Write the `description` frontmatter so it names history/decision questions across OpenSpec notes, changes and specs, and not code-only questions; verify against the "Skill triggers on history questions" scenarios
- [x] 2.2 Write the binary and freshness steps: `command -v devlog-index` (stop and tell the user to run `./install.sh` if absent), `status --json` once per task, `update` when the index is missing or files changed, with the first-run model download noted; verify against the "Freshness guidance" scenarios
- [x] 2.3 Write the querying section: `query --json "<text>"`, phrasing, `--k N`, stdout-only JSON, the result labels, which kinds are decisions, and reading threads before relying on a result; verify against the "Querying guidance" scenarios
- [x] 2.4 Write the failure section: keyword-only notices, missing index, no workspace (no `init`), no results, exit codes 0/1/2; verify against the "Failure handling guidance" scenarios
- [x] 2.5 Run the CLI against a real workspace as the skill directs (`status --json`, `query --json`, `--k`) and verify each command and flag in the skill works as written, noting the output in the devlog note
- [x] 2.6 Self-review the skill against `README.md` and the `workspace-query` spec and verify no command, flag, notice or exit code is absent from or contradicts them

## 3. Documentation

- [ ] 3.1 Add an "Agent skill" section to `README.md`: `/plugin marketplace add`, `/plugin install`, that the binary must already be installed, and a note to update the skill when the CLI's flags or notices change; verify the commands are copy-pasteable and match the manifests' names
- [ ] 3.2 Run `claude plugin validate .` again and `make gates`; verify `VALIDATE_EXIT:0`, `BUILD_EXIT:0`, `TEST_EXIT:0`, `FORMAT_EXIT:0` and `GATES_EXIT:0` are all seen

## Workflow follow-up

- Whole-change review, then offer `code-review` and `/opsx:archive` per CLAUDE.md.
