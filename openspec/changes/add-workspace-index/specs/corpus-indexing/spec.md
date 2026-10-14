# Spec Delta

## Purpose

Builds and maintains a local, incrementally updated index of a workspace's OpenSpec history and specs,
so queries can find decisions and standards across all member repos.

## ADDED Requirements

### Requirement: Indexed sources
`update` SHALL index, for every member repo:
- every devlog note `openspec/changes/<change>/devlog/*.md` and `openspec/changes/archive/<change>/devlog/*.md`;
- `proposal.md`, `design.md` and `tasks.md` of active and archived changes;
- spec deltas `openspec/changes/<change>/specs/**/spec.md` of **active** changes;
- main specs `openspec/specs/**/spec.md`.

It SHALL NOT index spec deltas of archived changes, legacy `DEVLOG.md` files, or any file outside the
members' `openspec/` directories.

#### Scenario: Archived spec delta excluded
- **WHEN** a capability appears in a main spec and in an archived change's spec delta
- **THEN** only the main spec's text is indexed

#### Scenario: Active spec delta included
- **WHEN** an active change has a spec delta
- **THEN** that delta is indexed

#### Scenario: Legacy devlog excluded
- **WHEN** a change contains a `DEVLOG.md` file
- **THEN** it is not indexed

### Requirement: Chunking
Indexed files SHALL be divided into passages:
- a devlog note into paragraph groups of at least about 80 words (the final group may be shorter), each
  carrying the note's title;
- a spec into one passage per requirement, plus its purpose;
- other artifacts into one passage per `##` section.

#### Scenario: Long note split with title
- **WHEN** a devlog note titled "Decision: retry policy" has several paragraphs totalling 300 words
- **THEN** it yields more than one passage, and every passage includes the title "Decision: retry policy"

#### Scenario: Spec split by requirement
- **WHEN** a spec has three requirements
- **THEN** each requirement, with its scenarios, is a separate passage

### Requirement: Passage metadata
Every passage SHALL record its member repo, change name (none for a main spec), whether the change is
archived, its source file path, and its kind: `spec`, `spec-delta`, `proposal`, `design`, `tasks`, or for
devlog notes the note kind derived from the filename slug (`decision`, `stopped`, `section`, `answer`,
`change`, `review`, otherwise `note`). A devlog passage SHALL also record the note's timestamp from its
filename.

#### Scenario: Note kind and time from filename
- **WHEN** the note `20260312-0915-stopped-2-1-needs-credentials.md` in archived change `x` of repo `api` is indexed
- **THEN** its passages record repo `api`, change `x`, archived, kind `stopped`, time 2026-03-12 09:15

### Requirement: Incremental update
`update` SHALL re-process only files whose content has changed since the last update, SHALL index new
files, and SHALL remove passages of files that no longer exist. Running `update` from any member repo
SHALL refresh the whole workspace. An update interrupted part-way SHALL leave the previous index usable.

#### Scenario: Nothing changed
- **WHEN** `update` runs twice with no file changes in between
- **THEN** the second run computes no embeddings and reports zero files changed

#### Scenario: One new note
- **WHEN** one devlog note is added in one member and `update` runs from a different member
- **THEN** exactly that note's passages are added, and the run reports one file added

#### Scenario: Change archived
- **WHEN** an active change is moved into `archive/` and `update` runs
- **THEN** its passages are recorded as archived, and its spec deltas are no longer indexed

#### Scenario: File deleted
- **WHEN** an indexed file is deleted and `update` runs
- **THEN** no query returns passages from that file

### Requirement: Local embeddings with a pinned model
Semantic embeddings SHALL be computed on the local machine. The embedding model SHALL be downloaded once,
on first need, and cached; no indexed content SHALL leave the machine. The index SHALL record the model
identity and vector dimension it was built with; a command finding a different configured model SHALL
refuse to mix vectors and SHALL tell the user to rebuild.

#### Scenario: First update downloads the model
- **WHEN** `update` runs and the model is not cached
- **THEN** the model is downloaded to the cache, with progress reported, before embedding starts

#### Scenario: Model mismatch
- **WHEN** the index was built with model A and the tool is configured for model B
- **THEN** `update` refuses, naming both models and the rebuild command
- **AND** `query` returns lexical results only, with a notice naming both models and the rebuild command

#### Scenario: Embedding unavailable during update
- **WHEN** the model cannot be loaded during `update`
- **THEN** the update fails without changing the index

### Requirement: Model pinned by content
The embedding model SHALL be pinned to a fixed revision and a content hash. A downloaded model whose
content hash differs SHALL NOT enter the cache.

#### Scenario: Downloaded model has the wrong content hash
- **WHEN** the downloaded model's SHA-256 is not the pinned one
- **THEN** the download is discarded, nothing is cached, and the update fails naming both hashes without
  changing the index

### Requirement: Index status
`status` SHALL report the workspace name and root, each member with its passage count (or that it is
missing), the number of files changed since the last update, the time of the last update, and whether
the embedding model is cached.

#### Scenario: Stale index
- **WHEN** two notes were added since the last `update`
- **THEN** `status` reports two files changed since the last update
