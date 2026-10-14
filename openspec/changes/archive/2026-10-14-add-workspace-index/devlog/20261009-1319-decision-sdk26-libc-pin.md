# Decision: build against the macOS 26 SDK via ZIG_LIBC

<!-- Section: 1 · Tasks: 1.1 · Base: f10f567 -->

The first `zig build` failed in Zig's libc++ sub-compilation (pulled in by llama.cpp):
`use of undeclared identifier 'INFINITY'` in `libcxx/include/__random/clamp_to_integral.h`.

Cause: xcrun now selects macOS SDK 27.0. Its `math.h`, when modules are enabled, gets `INFINITY`/`NAN`
from `<float.h>` via `__need_infinity_nan`. Zig 0.16.0's bundled `float.h` doesn't implement that
macro (it's new in clang 22 / Apple clang 21; cf. LLVM libc++ PR #172539), so `INFINITY` is never
defined. SDK 26.5's `math.h` defines it directly. memlite (`749b246`) fails the same way on this
machine, so it's the toolchain, not this code.

- `SDKROOT` doesn't help: Zig asks `xcrun --sdk macosx`, which ignores it.
- A libc file (`ZIG_LIBC`) naming the SDK 26.5 include dir works, for the exe and for llama.cpp's C++
  compiles alike. Ghostty uses the same libc-file technique for SDK mismatches.

Asked Emmz, who chose **the Makefile pins SDK 26** over doing it in `build.zig` (would have to reach
into the llama.cpp dependency's compiles) or stopping to fix the toolchain:

- `Makefile`: `libc` target writes `.zig-cache/libc-sdk26.txt` from the newest
  `/Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk`; `ZIG_LIBC` exported; `build`/`test` depend
  on it. `make deps` checks the SDK 26 is present.
- `docs/dependencies.md` row + note; `CLAUDE.md` gate line; design D11 amended.
- Bare `zig build` still fails on this machine — run Zig through `make`.

Also: unpacking the llama.cpp packages into `zig-pkg/` needs the build unsandboxed once (the sandbox
denies writing `.gitmodules`). After that, `make build`/`make test` run sandboxed.

## Next

- Drop the SDK 26 pin once a Zig release builds against SDK 27 (check on each Zig bump).
- memlite has the same breakage; not fixed here (out of scope) — Emmz may want the same Makefile pin there.
