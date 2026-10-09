# Proposal: add retry

Alpha's calls to the token service fail outright whenever the service has a blip, which shows up as
user-facing errors several times a week.

## Why

Most token-service failures last under a second. Retrying them inside the client hides the blip from
users without anyone having to page.

## What Changes

- Retry token requests on connection failure and HTTP 503.
- Read credentials from the environment.
