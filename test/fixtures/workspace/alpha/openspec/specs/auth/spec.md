# auth Specification

## Purpose

Authenticates calls from alpha to the upstream token service and retries transient failures so that a
brief outage of the token service does not fail user requests.

## Requirements

### Requirement: Token refresh
The client SHALL refresh its access token before it expires, using the refresh token issued with it.

#### Scenario: Token near expiry
- **WHEN** a call is made with fewer than 60 seconds of token lifetime left
- **THEN** the token is refreshed first

### Requirement: Retry transient failures
The client SHALL retry a failed token request at most twice, with a fixed 500 ms delay, and only for
connection failures and HTTP 503.

#### Scenario: Upstream returns 503
- **WHEN** the token service returns 503 twice and then 200
- **THEN** the call succeeds after two retries

### Requirement: Credentials from the environment
The client SHALL read its client id and secret from the environment, never from configuration files.

#### Scenario: Secret missing
- **WHEN** the client secret is not set
- **THEN** startup fails naming the missing variable
