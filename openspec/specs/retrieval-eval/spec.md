# retrieval-eval Specification

## Purpose

Makes retrieval quality measurable: a workspace's golden questions, each with the sources that must be
found, are checked so that ranking changes cannot silently lose the answers that matter.

## Requirements

### Requirement: Golden set
A workspace's golden set, when present, SHALL be a file beside its config listing questions, each with one or more
expected source file paths (relative to the workspace root). The golden set SHALL belong to the workspace,
not to the tool's own repository.

#### Scenario: Golden set location
- **WHEN** the workspace config is at `<root>/`
- **THEN** its golden set is read from `<root>/`

### Requirement: Evaluation
`eval` SHALL run every golden question as a query with default settings and SHALL report, per question,
the rank of each expected source among the primary results. It SHALL exit zero only if every expected
source appears within the primary results (top ten), and non-zero otherwise, except as the Known misses
requirement allows.

#### Scenario: All found
- **WHEN** every expected source is within the top ten for its question
- **THEN** `eval` prints each question with its ranks and exits 0

#### Scenario: One missed
- **WHEN** one expected source is outside the top ten
- **THEN** `eval` names the question and the missing source and exits non-zero

#### Scenario: No golden set
- **WHEN** `eval` runs in a workspace without a golden set
- **THEN** it exits non-zero saying the golden set is missing and where it is expected

#### Scenario: Expected source not indexed
- **WHEN** an expected source path is not in the index
- **THEN** `eval` reports it as not indexed, distinct from not ranked, and exits non-zero

### Requirement: Known misses
A golden question SHALL be able to be marked as a known miss. `eval` SHALL report a known miss's ranks
like any other question but SHALL NOT fail because its expected sources are outside the top ten. When
every expected source of a known miss appears within the top ten, `eval` SHALL report it as unexpectedly
found, so that the mark can be removed, without failing. An expected source of a known miss that is not
indexed SHALL still fail `eval`.

#### Scenario: Known miss still missing
- **WHEN** a question marked as a known miss has its expected source at rank 41
- **THEN** `eval` reports the question as a known miss with rank 41 and does not fail because of it

#### Scenario: Known miss now found
- **WHEN** a question marked as a known miss has its expected source at rank 3
- **THEN** `eval` reports it as unexpectedly found, suggesting the mark be removed, and does not fail because of it

#### Scenario: Known miss not indexed
- **WHEN** a question marked as a known miss expects a source that is not in the index
- **THEN** `eval` reports it as not indexed and exits non-zero
