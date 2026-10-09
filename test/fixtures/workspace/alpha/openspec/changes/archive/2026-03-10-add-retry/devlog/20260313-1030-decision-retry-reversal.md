# Decision: retry reversal

<!-- Section: 2 -->

Reverses the policy in 20260310-1015-decision-retry-policy. Once the sandbox tenant was in use, the
token service turned out to be shared with two other teams, so the assumption that alpha is its only
caller was wrong. With several callers failing together, a fixed delay makes them all retry in lockstep.

We now use exponential backoff with full jitter, starting at 200 ms, still capped at two retries so the
worst-case added latency stays near one second. The tests seed the jitter source so they remain exact.

## Next

- Update the retry tests for jittered backoff.
