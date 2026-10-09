# Stopped: 2.1 needs credentials

<!-- Section: 2 · Tasks: 2.1 -->

Task 2.1 reads the client id and secret from the environment, but there are no test credentials for
the token service in any environment we can reach. The integration test cannot run without them, and
inventing placeholder values would make the test pass without proving anything about the real service.

## Next

- Waiting on Emmz: where do test credentials for the token service come from?
