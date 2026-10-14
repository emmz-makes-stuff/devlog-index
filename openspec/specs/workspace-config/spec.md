# workspace-config Specification

## Purpose

Declares which repos form one searchable workspace, and lets any command run from inside a member repo
find that workspace without being told where it is.

## Requirements

### Requirement: Workspace declaration
A workspace SHALL be declared by a config file at the workspace root, containing the workspace's name and
the list of its member repo paths. Member paths SHALL be resolved relative to the config file's
directory. Only declared members SHALL be indexed or queried; other directories under the workspace root
SHALL be ignored.

#### Scenario: Undeclared sibling repo is ignored
- **WHEN** the workspace root contains repos `a`, `b` and `scratch`, and the config declares only `a` and `b`
- **THEN** `update` indexes `a` and `b` only, and no query result comes from `scratch`

#### Scenario: Member path does not exist
- **WHEN** the config declares a member path that does not exist or has no `openspec/` directory
- **THEN** `update` and `status` report that member by path as missing, and the other members are still indexed

### Requirement: Creating a workspace
`init` SHALL create a workspace config in the current directory from a given name and member paths. It
SHALL refuse to overwrite an existing config.

#### Scenario: Init writes a config
- **WHEN** Emmz runs `init acme infra api auth admin tools` in the workspace root
- **THEN** a config naming workspace `acme` with those five members exists in that directory

#### Scenario: Init refuses to overwrite
- **WHEN** `init` is run in a directory that already has a workspace config
- **THEN** the command fails naming the existing file, and the file is unchanged

### Requirement: Workspace resolution
Every command except `init` SHALL locate its workspace by searching the current directory and then each
parent directory in turn for a workspace config; the nearest config SHALL win. If none is found, the
command SHALL fail with a message saying no workspace was found and how to create one.

#### Scenario: Query from inside a member repo
- **WHEN** a command runs in `<root>/api/src/` and the config is at `<root>/`
- **THEN** it uses the workspace declared at `<root>/`, covering all its members

#### Scenario: Nested configs
- **WHEN** configs exist at both `~/code/` and `~/code/acme/`, and a command runs inside `~/code/acme/api/`
- **THEN** the `~/code/acme/` workspace is used

#### Scenario: No workspace
- **WHEN** a command runs in a directory with no config in it or any parent
- **THEN** it exits non-zero with a message naming `init` as the way to create one

### Requirement: Workspace data stays beside the config
The index and the golden query set for a workspace SHALL be stored in the workspace root beside its
config. No indexed content SHALL be written anywhere else, and no indexed content SHALL be sent over the
network.

#### Scenario: Index location
- **WHEN** `update` runs for a workspace whose config is at `<root>/`
- **THEN** the index is created or updated under `<root>/` and nowhere else
