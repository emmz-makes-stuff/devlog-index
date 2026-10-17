## Purpose

Defines the platforms `devlog-index` runs on and the behaviour that must be the same on each, so a workspace
indexed on Windows answers queries like one indexed on macOS or Linux.

## ADDED Requirements

### Requirement: Supported platforms
`devlog-index` SHALL run on macOS arm64, Linux x64, Linux arm64 and Windows x64, with the same commands,
options and output formats on each.

#### Scenario: Same output on Windows
- **WHEN** the same workspace is indexed and queried with `query --json` on Windows x64 and on Linux x64
- **THEN** both outputs have the same fields, and each passage's `path` is reported with `/` separators

### Requirement: Model cache location
The embedding model SHALL be cached under `.devlog-index/models/` in the user's home directory, taken from
`HOME` when set and otherwise from `USERPROFILE`. If neither is set, the command SHALL fail naming both
variables.

#### Scenario: Windows home
- **WHEN** `update` runs on Windows with `USERPROFILE=C:\Users\emmz` and no `HOME`
- **THEN** the model is cached under `C:\Users\emmz\.devlog-index\models\`

#### Scenario: No home directory
- **WHEN** a command that needs the model runs with neither `HOME` nor `USERPROFILE` set
- **THEN** it fails with a message naming both variables and writes nothing

### Requirement: Quiet model loading
Loading the model SHALL NOT print the inference library's diagnostics to the terminal on any supported
platform. If they cannot be silenced, loading SHALL proceed with them visible rather than fail.

#### Scenario: Windows query output
- **WHEN** `query` runs on Windows against an indexed workspace
- **THEN** stderr holds no `llama_model_loader:` or `print_info:` lines

#### Scenario: Silencing unavailable
- **WHEN** the platform refuses to redirect stderr
- **THEN** the model still loads and the command succeeds

### Requirement: Symlinks where unsupported
Where symlinks can't be created or followed, such as a Windows account without the privilege, discovery
SHALL index every real file and folder and SHALL NOT fail. A link that can't be followed SHALL be reported
as a broken link and skipped.

#### Scenario: Workspace with no links
- **WHEN** `update` runs on Windows over a workspace containing no symlinks
- **THEN** every `openspec/` file is indexed and no link is reported

#### Scenario: Link that can't be followed
- **WHEN** a member contains a link the platform can't resolve
- **THEN** `update` lists its path as a broken link, skips it, and indexes everything else
