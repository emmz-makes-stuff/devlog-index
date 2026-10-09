# devlog-index — gate targets.
#
# Every gate prints its own exit code as `LABEL_EXIT:<n>` and exits with it, so a
# result can be quoted rather than inferred from output that may look clean.
# `gates` runs the whole set with -k, so one run reports every failure.

SHELL := /bin/bash

CHANGES := $(notdir $(patsubst %/,%,$(filter-out %/archive/,$(wildcard openspec/changes/*/))))

.PHONY: build test format validate changes gates deps

build:
	@zig build; code=$$?; echo "BUILD_EXIT:$$code"; exit $$code

test:
	@zig build test --summary all; code=$$?; echo "TEST_EXIT:$$code"; exit $$code

format:
	@zig fmt --check src build.zig; code=$$?; echo "FORMAT_EXIT:$$code"; exit $$code

# Validates every active change. No active change is a failure, not a silent pass.
validate:
	@fail=0; \
	if [ -z "$(CHANGES)" ]; then \
		echo "no active change found under openspec/changes/"; fail=1; \
	else \
		for c in $(CHANGES); do openspec validate $$c --strict || fail=1; done; \
	fi; \
	echo "VALIDATE_EXIT:$$fail"; exit $$fail

changes:
	@echo "$(CHANGES)"

gates:
	@$(MAKE) --no-print-directory -k build test format validate; code=$$?; \
	echo "GATES_EXIT:$$code"; exit $$code

# Every tool and login in docs/dependencies.md — keep the two in step. Not part of
# `gates`: it checks the machine, not the code, and auth checks may need the network.
deps:
	@fail=0; \
	zig version >/dev/null 2>&1 || { echo "MISSING zig — download 0.16 from https://ziglang.org/download"; fail=1; }; \
	zig version 2>/dev/null | grep -q '^0\.16\.' || { echo "WRONG VERSION zig — need 0.16.x"; fail=1; }; \
	xcrun --show-sdk-path >/dev/null 2>&1 || { echo "MISSING macOS SDK — xcode-select --install"; fail=1; }; \
	openspec --version >/dev/null 2>&1 || { echo "MISSING openspec — npm i -g @fission-ai/openspec"; fail=1; }; \
	git --version >/dev/null 2>&1 || { echo "MISSING git — brew install git"; fail=1; }; \
	echo "DEPS_EXIT:$$fail"; exit $$fail
