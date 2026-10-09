## Why

Alpha fetches a new token for every request burst; caching it until near expiry cuts token-service load.

## What Changes

- Cache the access token in memory until 60 seconds before expiry.
