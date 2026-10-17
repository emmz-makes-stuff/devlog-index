# Dependencies

<!-- Maintained by /emmz:architecture; verified by `make deps`. -->

| Tool | Why | Version | Check | Auth check | Install / auth |
|---|---|---|---|---|---|
| zig | build, test, fmt | 0.16.x (memlite's build API) | `zig version \| grep -q '^0\.16\.'` | — | Download 0.16 from https://ziglang.org/download (macOS arm64) and put `zig` on `PATH` |
| Xcode Command Line Tools | macOS SDK; llama.cpp links Accelerate/Metal | any | `xcrun --show-sdk-path` | — | `xcode-select --install` |
| macOS SDK 26.x | Zig 0.16.0's libc++ can't compile against SDK 27 headers; `make` points Zig at SDK 26 via `ZIG_LIBC` | 26.x, in the Command Line Tools | `ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk` | — | Command Line Tools for Xcode 26 from https://developer.apple.com/download/all/ |
| openspec | change tracking | any | `openspec --version` | — | `npm i -g @fission-ai/openspec` |
| git | source control | any | `git --version` | — | `brew install git` |
| zip, unzip | `scripts/package-release.sh` builds the windows-x64 zip; `scripts/test-release-scripts.sh` reads it back | any (macOS ships both) | `zip -v >/dev/null && unzip -v >/dev/null` | — | `brew install zip unzip` |

Notes:

- The first `zig build` fetches the `daemonicai/llama.cpp.zig` fork from GitHub (pinned in
  `build.zig.zon`), so it needs network access.
- The embedding model (`nomic-embed-text-v1.5` Q5_K_M GGUF, ~99 MB) is not a tool dependency: the binary
  downloads it on first `update`, and `status` reports whether it is present. It is pinned to a Hugging
  Face commit and a SHA-256 in `src/model_url.zig`; a download with another hash is discarded.
- Bare `zig build` fails on a machine whose selected SDK is 27 (`use of undeclared identifier
  'INFINITY'` in libc++). Build through `make`, which sets `ZIG_LIBC`; drop the SDK 26 row once a Zig
  release builds against SDK 27.
