# Stopped: `check` failed on the v0.0.2-rc1 tag run (AMX link error)

<!-- Section: 6 · Tasks: 6.1–6.4 · Base: 4d339d8 · Code commit: b9e9e24 (pushed) -->

**State.** The §6 code is committed (`b9e9e24`) and pushed; `tasks.md` §6 is unticked pending remote
verification. Local `make gates`: `BUILD_EXIT:0 TEST_EXIT:0 SCRIPTS_EXIT:0 FORMAT_EXIT:0 VALIDATE_EXIT:0
GATES_EXIT:0`. Mutation check for 6.4 (owner flags dropped) failed all three targets, as intended.

**Verified.**
- 6.2/6.3: dispatch run 38931406105 on the branch: `check` success, `build` success, `publish` skipped.
- 6.4: positive owner check, README note.

**Unexpected.** Tag push `v0.0.2-rc1` → run 38932488815: `check` **failed** in `zig build test --summary all`:

    compile exe devlog-index Debug native 1 errors
    error: undefined symbol: _Z28ggml_backend_amx_buffer_typev

The same job passed ~10 minutes earlier on the branch dispatch (and in §3's CI runs). Both are cold, native
Debug builds on ubuntu-24.04, so the likely difference is the runner's CPU: the llama.cpp fork picks the AMX
backend from host features, and the build seems not to compile `amx` sources in that case. Unproven: the
runner CPU isn't logged. `build` (cross-compiled, baseline CPU) is unaffected. The new gate did its job:
`publish` can't run, so **no Release exists** for `v0.0.2-rc1`.

**Left on the remote.** Tag `v0.0.2-rc1` (on `b9e9e24`) and run 38932488815. 6.1 (dispatch on a tag ref
doesn't publish) is **not yet verified**: with `check` failing, `publish` would be skipped for the wrong reason.

**Question for Emmz.** The AMX failure is a latent flake in the native test build (`build.zig` / the fork),
outside this change, but now it can block releases. Options:
1. Fix it in this change as `6.5` (investigate `build.zig`'s AMX handling; likely pin the CI test target, e.g.
   `-Dcpu=baseline`, or fix the fork's source list).
2. Work around it in `ci.yml`/`release.yml` only (`zig build test -Dcpu=baseline`), and open a separate change
   for the real fix.
3. Re-run `check` to confirm it's hardware-dependent first.

## Next

- Wait for Emmz's answer. On option 1/2: add the task to §6, build it, then re-run: dispatch on the tag ref for
  6.1 with `check` green, confirm `publish` is skipped and no Release exists.
- Then delete tag `v0.0.2-rc1` (`git push origin :refs/tags/v0.0.2-rc1`; `git tag -d`), tick §6, write the
  section-done note, amend/commit, hand off. Then re-offer `/opsx:archive`.
- Deferred: `restore-keys` etc. all done; remaining follow-ups as in the change-done note.
