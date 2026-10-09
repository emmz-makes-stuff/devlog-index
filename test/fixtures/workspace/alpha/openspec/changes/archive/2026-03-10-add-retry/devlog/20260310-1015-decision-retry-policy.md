# Decision: retry policy

<!-- Section: 1 · Tasks: 1.1 -->

We need a retry policy for the token client. The token service fails in short bursts, almost always
under a second, and the failures are either refused connections while a pod restarts or HTTP 503 from
the load balancer while it drains. Neither failure means the request was wrong, so retrying the same
request is safe: token requests are idempotent and carry no side effects on the server.

The options considered were a fixed delay, exponential backoff with jitter, and no retry at all with a
circuit breaker instead. Exponential backoff is the textbook answer for shared upstreams because it
spreads retries out when many clients fail at once, but alpha is the only caller of this token service
and makes at most a handful of calls per second, so the thundering-herd argument does not apply here.

We chose a fixed 500 ms delay with at most two retries. It is simple to reason about, it bounds the
worst-case added latency at one second, and the tests can assert it exactly without mocking a random
source. If the numbers turn out wrong in production, they live in one constant and can be tuned
without touching the call sites or the tests that exercise the give-up path. A circuit breaker was rejected for now because the failures are too short for a breaker to
open before the service recovers, so it would add state without changing any outcome.

Only connection failures and HTTP 503 are retried. A 401 means the credentials are wrong and retrying
cannot fix it; a 500 may mean the request itself triggers a bug, and retrying it would triple the noise. Timeouts are
not retried either, because a timed-out request may still complete upstream and we would rather surface
the slowness than hide it behind a second attempt.

## Next

- 1.2 tests for 503 and connection failure.
