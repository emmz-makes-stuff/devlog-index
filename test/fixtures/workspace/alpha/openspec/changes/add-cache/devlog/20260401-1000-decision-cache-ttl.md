# Decision: cache TTL

The cache keeps a token until 60 seconds before its expiry rather than a fixed TTL, so a short-lived
token issued during an incident is never served stale.

## Next

- 1.1 implement the cache.
