# Dependencies

<!-- Maintained by /emmz:architecture; verified by `make deps`. -->

| Tool | Why | Version | Check | Auth check | Install / auth |
|---|---|---|---|---|---|
| zig | build, test, fmt | 0.16.x (memlite's build API) | `zig version \| grep -q '^0\.16\.'` | — | Download 0.16 from https://ziglang.org/download (macOS arm64) and put `zig` on `PATH` |
| Xcode Command Line Tools | macOS SDK; llama.cpp links Accelerate/Metal | any | `xcrun --show-sdk-path` | — | `xcode-select --install` |
| openspec | change tracking | any | `openspec --version` | — | `npm i -g @fission-ai/openspec` |
| git | source control | any | `git --version` | — | `brew install git` |

Notes:

- The first `zig build` fetches the `daemonicai/llama.cpp.zig` fork from GitHub (pinned in
  `build.zig.zon`), so it needs network access.
- The embedding model (`nomic-embed-text-v1.5` Q5_K_M GGUF, ~99 MB) is not a tool dependency: the binary
  downloads it on first `update`, and `status` reports whether it is present.
