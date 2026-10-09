# Spec Delta

## ADDED Requirements

### Requirement: Retry transient failures
ARCHIVED-DELTA-MARKER: the client SHALL retry with exponential backoff (superseded wording; the main spec
holds the current text). This archived delta must never be indexed.

#### Scenario: Upstream returns 503
- **WHEN** the token service returns 503
- **THEN** the call is retried with backoff
