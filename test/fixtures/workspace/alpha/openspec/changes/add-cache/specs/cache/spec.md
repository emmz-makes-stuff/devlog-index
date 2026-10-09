# Spec Delta

## ADDED Requirements

### Requirement: Token cache
ACTIVE-DELTA-MARKER: the client SHALL reuse a cached access token until 60 seconds before it expires.

#### Scenario: Cached token reused
- **WHEN** two calls are made 10 seconds apart with a token valid for an hour
- **THEN** only one token request is sent
