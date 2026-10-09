# Design: add retry

## Context

The token client is a thin wrapper over HTTP with no retry today.

## Decisions

### D1. Retry in the client, not a proxy
A sidecar proxy was considered and rejected: it adds a deployable for a few lines of code.

## Empty section

## Risks

Retrying a slow upstream can amplify load; the retry count is capped to limit that.
