# Spec Delta

## Purpose

Answers plain-language questions about a workspace's decisions, standards and history with ranked,
labelled passages and the notes that later refer back to them, for Emmz in a terminal and Claude in a
session.

## ADDED Requirements

### Requirement: Hybrid union retrieval
`query "<text>"` SHALL rank passages both lexically and by semantic similarity, and SHALL return the
union of each method's top results (five from each by default, configurable), with duplicates merged.
Each result SHALL state which method(s) found it. Passages from all workspace members SHALL be searched.

#### Scenario: Concept found without shared words
- **WHEN** the query asks for "the standard for naming services" and the relevant spec calls it a "naming convention" without the word "standard"
- **THEN** that spec's passage appears in the results, labelled as found semantically

#### Scenario: Exact term found
- **WHEN** the query contains a distinctive term that appears verbatim in one note
- **THEN** that note's passage appears in the results, labelled as found lexically

#### Scenario: Cross-repo answer
- **WHEN** the query is run from member `api` and the best passage is in member `infra`
- **THEN** the `infra` passage is returned

#### Scenario: Result count
- **WHEN** a query runs with default settings
- **THEN** at most ten distinct passages are returned as primary results

### Requirement: Result labelling
Each result SHALL show the passage text and its member repo, change (or "main spec"), archived or active,
kind, note timestamp where it has one, source file path, and finding method(s).

#### Scenario: Labels on a devlog result
- **WHEN** a result comes from an archived change's `decision-*` note
- **THEN** it is shown with repo, change, "archived", kind `decision`, the note's timestamp and file path

### Requirement: Thread expansion
For each result from a devlog note, the query SHALL also return the later notes in the same change that
refer back to that note, by its filename, by its time as written in a note ("the 1346 note"), or by its
section as written ("§7-done", "section 7 done"). Thread notes SHALL be shown under the result they
follow, in time order, marked as thread entries rather than ranked results. The tool SHALL NOT hide or
demote any result on the grounds that it was superseded.

#### Scenario: Reversal surfaces with the reversed note
- **WHEN** note `…-0116-section-6-done.md` matches the query, and a later note in the same change says "This supersedes the §6-done note's …"
- **THEN** the later note is returned as a thread entry under the section-6-done result

#### Scenario: Reference by time
- **WHEN** a matching note is `20261007-1346-….md` and a later note in the same change says "reverses the 1346 note's decision"
- **THEN** the later note is returned as a thread entry under it

#### Scenario: Other changes not threaded
- **WHEN** a note in a different change mentions the same filename-like time "1346"
- **THEN** it is not returned as a thread entry

### Requirement: Output formats
Results SHALL be human-readable text by default. With `--json`, the query SHALL emit one JSON object per
result line, including all labels, the passage text and its thread entries, and nothing else on stdout.

#### Scenario: Machine-readable output
- **WHEN** Claude runs `query --json "why is the schema private"`
- **THEN** every stdout line parses as a JSON object containing the result's labels, text and thread

### Requirement: Degraded and empty states
A query SHALL never present partial results as complete.

#### Scenario: No index yet
- **WHEN** `query` runs in a workspace that has never been updated
- **THEN** it exits non-zero saying the index is missing and naming `update`

#### Scenario: Semantic search unavailable
- **WHEN** the embedding model cannot be loaded at query time
- **THEN** lexical results are still returned, and the output states clearly that semantic search was skipped and why

#### Scenario: Stale index warning
- **WHEN** files have changed since the last `update`
- **THEN** results are returned with a notice of how many files are unindexed, naming `update`

### Requirement: Query latency
A query on a workspace of ~3,200 passages SHALL complete in under one second from process
start on Emmz's development machine.

#### Scenario: Cold query budget
- **WHEN** `query` runs as a fresh process on the real workspace
- **THEN** it finishes in under one second wall-clock
