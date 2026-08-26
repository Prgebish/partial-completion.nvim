SHELL := /bin/sh

DOCS := README.md
INTERNAL_DOCS := task_plan.md architecture.md features.md research.md \
	spec/behavior.md spec/public-api.md
LOCAL_INTERNAL_DOCS := $(wildcard $(INTERNAL_DOCS))
CONTRACT_SOURCES := scripts/verify_contracts.lua tests/contract/cases.lua \
	tests/contract/run.lua scripts/observe_emacs.el
LUA_DIRS := lua plugin tests
LUA_SCRIPTS := scripts/benchmark.lua scripts/benchmark_reference.lua scripts/check_startup.lua scripts/integration.lua \
	scripts/adapter_smoke.lua scripts/interactive_adapter_smoke.lua scripts/interactive_cmdline_smoke.lua \
	scripts/interactive_real_config_smoke.lua scripts/pty_adapter_smoke.lua scripts/pty_cmdline_smoke.lua \
	scripts/pty_real_config_smoke.lua scripts/test.lua scripts/test_harness_selftest.lua \
	scripts/verify_contracts.lua scripts/portability.lua
ADAPTER_DEPS_DIR ?= $(CURDIR)/deps
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
LUAJIT_PREFIX ?= $(shell brew --prefix luajit)
else
LUAJIT_PREFIX ?= /usr
endif
LUACHECK := .luarocks-luajit/bin/luacheck

.PHONY: verify verify-docs verify-contracts format format-check lint test test-harness-selftest \
	contract-tests contract-api contract-matcher contract-path contract-replacement \
	contract-session integration adapter-deps adapter-integration interactive-adapter-smoke \
	interactive-smoke interactive-smoke-selftest portability-check benchmark-check \
	benchmark-reference-selftest real-config-smoke observe-emacs

.PHONY: benchmark-reference

verify: verify-docs verify-contracts format-check lint test-harness-selftest test contract-api \
	contract-matcher contract-path contract-replacement contract-session integration adapter-integration \
	interactive-smoke-selftest interactive-smoke interactive-adapter-smoke portability-check \
	benchmark-reference-selftest benchmark-check

verify-docs:
	@set -eu; \
	for file in $(DOCS) $(LOCAL_INTERNAL_DOCS); do \
		test -s "$$file" || { echo "missing or empty: $$file" >&2; exit 1; }; \
		fences=$$(rg -c '^```' "$$file" || true); \
		test $$((fences % 2)) -eq 0 || { echo "unbalanced code fences: $$file" >&2; exit 1; }; \
	done
	@! rg -n '[[:blank:]]+$$' $(DOCS) $(LOCAL_INTERNAL_DOCS) $(CONTRACT_SOURCES) Makefile
	@if test -f task_plan.md; then rg -q '^## Status$$' task_plan.md; fi
	@if test -f architecture.md; then rg -q '^## Planned File Structure$$' architecture.md; fi
	@if test -f features.md; then rg -q '^## Current Product Status$$' features.md; fi
	@if test -f research.md; then rg -q '^## Ecosystem Survey$$' research.md; fi
	@if test -f spec/behavior.md; then rg -q '^# Phase 1 Behavioral Contract$$' spec/behavior.md; fi
	@if test -f spec/public-api.md; then rg -q '^# Phase 1 Public API Contract$$' spec/public-api.md; fi
	@echo "Documentation verification passed"

verify-contracts:
	@nvim --clean --headless -l scripts/verify_contracts.lua

format:
	@stylua $(LUA_DIRS) $(LUA_SCRIPTS)

format-check:
	@stylua --check $(LUA_DIRS) $(LUA_SCRIPTS)

$(LUACHECK):
	@luarocks --lua-dir "$(LUAJIT_PREFIX)" --lua-version 5.1 \
		--tree .luarocks-luajit install luacheck 1.2.0

lint: $(LUACHECK)
	@$(LUACHECK) $(LUA_DIRS) $(LUA_SCRIPTS)

test:
	@set -eu; \
	test_root=$$(mktemp -d); \
	trap 'rm -rf "$$test_root"' EXIT INT TERM; \
	XDG_CONFIG_HOME="$$test_root/config" \
	XDG_DATA_HOME="$$test_root/data" \
	XDG_STATE_HOME="$$test_root/state" \
	XDG_CACHE_HOME="$$test_root/cache" \
	nvim --headless -u tests/minimal_init.lua -l scripts/test.lua

test-harness-selftest:
	@set -eu; \
	test_root=$$(mktemp -d); \
	trap 'rm -rf "$$test_root"' EXIT INT TERM; \
	for mode in scheduled warning leak inactive_timer raw_fd empty_file load_warning load_scheduled load_timer \
		mapping_local mapping_changed; do \
		if XDG_CONFIG_HOME="$$test_root/config" \
			XDG_DATA_HOME="$$test_root/data" \
			XDG_STATE_HOME="$$test_root/state" \
			XDG_CACHE_HOME="$$test_root/cache" \
			nvim --headless -u tests/minimal_init.lua \
			-l scripts/test_harness_selftest.lua "$$mode" \
			>"$$test_root/$$mode.log" 2>&1; then \
			cat "$$test_root/$$mode.log"; \
			echo "test harness accepted $$mode failure" >&2; \
			exit 1; \
		fi; \
		rg -q -e "$$mode-selftest-sentinel" -e "test file returned no tests" \
			-e "leaked libuv handles" -e "leaked OS file descriptors" \
			-e "leaked mappings" -e "unexpected warning" "$$test_root/$$mode.log"; \
	done; \
	echo "Test harness async-failure self-check passed"

# This is the complete future behavior suite. It is intentionally red after
# Phase 1 and is added to verify group-by-group as runtime modules land.
contract-tests:
	@nvim --clean --headless -l tests/contract/run.lua $(CONTRACT_GROUP)

contract-api:
	@nvim --clean --headless -l tests/contract/run.lua api

contract-matcher:
	@nvim --clean --headless -l tests/contract/run.lua matcher

contract-path:
	@nvim --clean --headless -l tests/contract/run.lua path

contract-replacement:
	@nvim --clean --headless -l tests/contract/run.lua replacement

contract-session:
	@nvim --clean --headless -l tests/contract/run.lua session

integration:
	@set -eu; \
	test_root=$$(mktemp -d); \
	trap 'rm -rf "$$test_root"' EXIT INT TERM; \
	XDG_CONFIG_HOME="$$test_root/config" \
	XDG_DATA_HOME="$$test_root/data" \
	XDG_STATE_HOME="$$test_root/state" \
	XDG_CACHE_HOME="$$test_root/cache" \
	nvim --headless -u tests/minimal_init.lua -l scripts/check_startup.lua; \
	XDG_CONFIG_HOME="$$test_root/config" \
	XDG_DATA_HOME="$$test_root/data" \
	XDG_STATE_HOME="$$test_root/state" \
	XDG_CACHE_HOME="$$test_root/cache" \
	nvim --headless -u tests/minimal_init.lua -l scripts/integration.lua

adapter-deps:
	@PARTIAL_COMPLETION_DEPS_DIR="$(ADAPTER_DEPS_DIR)" \
		sh scripts/bootstrap_adapter_deps.sh

adapter-integration: adapter-deps
	@set -eu; \
	for adapter in telescope blink nvim_cmp; do \
		test_root=$$(mktemp -d); \
		trap 'rm -rf "$$test_root"' EXIT INT TERM; \
		PARTIAL_COMPLETION_DEPS_DIR="$(ADAPTER_DEPS_DIR)" \
		XDG_CONFIG_HOME="$$test_root/config" \
		XDG_DATA_HOME="$$test_root/data" \
		XDG_STATE_HOME="$$test_root/state" \
		XDG_CACHE_HOME="$$test_root/cache" \
		nvim --headless -u tests/minimal_init.lua -l scripts/adapter_smoke.lua "$$adapter"; \
		rm -rf "$$test_root"; \
		trap - EXIT INT TERM; \
	done

interactive-adapter-smoke: adapter-deps
	@set -eu; \
	test_root=$$(mktemp -d); \
	trap 'rm -rf "$$test_root"' EXIT INT TERM; \
	PARTIAL_COMPLETION_DEPS_DIR="$(ADAPTER_DEPS_DIR)" \
	XDG_CONFIG_HOME="$$test_root/config" \
	XDG_DATA_HOME="$$test_root/data" \
	XDG_STATE_HOME="$$test_root/state" \
	XDG_CACHE_HOME="$$test_root/cache" \
	nvim --headless -u tests/minimal_init.lua -l scripts/pty_adapter_smoke.lua

interactive-smoke:
	@set -eu; \
	test_root=$$(mktemp -d); \
	trap 'rm -rf "$$test_root"' EXIT INT TERM; \
	XDG_CONFIG_HOME="$$test_root/config" \
	XDG_DATA_HOME="$$test_root/data" \
	XDG_STATE_HOME="$$test_root/state" \
	XDG_CACHE_HOME="$$test_root/cache" \
	nvim --headless -u tests/minimal_init.lua -l scripts/pty_cmdline_smoke.lua

interactive-smoke-selftest:
	@set -eu; \
	test_root=$$(mktemp -d); \
	trap 'rm -rf "$$test_root"' EXIT INT TERM; \
	if PARTIAL_COMPLETION_SMOKE_INJECT_WARNING=1 \
		XDG_CONFIG_HOME="$$test_root/config" \
		XDG_DATA_HOME="$$test_root/data" \
		XDG_STATE_HOME="$$test_root/state" \
		XDG_CACHE_HOME="$$test_root/cache" \
		nvim --headless -u tests/minimal_init.lua -l scripts/pty_cmdline_smoke.lua \
		>"$$test_root/smoke.log" 2>&1; then \
		cat "$$test_root/smoke.log"; \
		echo "native PTY smoke accepted a warning" >&2; \
		exit 1; \
	fi; \
	rg -q 'native-pty-warning-selftest-sentinel' "$$test_root/smoke.log"; \
	echo "Interactive PTY warning self-check passed"

real-config-smoke:
	@nvim --headless -i NONE -u tests/minimal_init.lua -l scripts/pty_real_config_smoke.lua

portability-check:
	@nvim --clean --headless -l scripts/portability.lua

benchmark-check: adapter-deps
	@set -eu; \
	test_root=$$(mktemp -d); \
	trap 'rm -rf "$$test_root"' EXIT INT TERM; \
	XDG_CONFIG_HOME="$$test_root/config" \
	XDG_DATA_HOME="$$test_root/data" \
	XDG_STATE_HOME="$$test_root/state" \
	XDG_CACHE_HOME="$$test_root/cache" \
	PARTIAL_COMPLETION_DEPS_DIR="$(ADAPTER_DEPS_DIR)" \
	nvim --headless -u tests/minimal_init.lua -l scripts/benchmark.lua

benchmark-reference:
	@set -eu; \
	test -n "$${PARTIAL_COMPLETION_REFERENCE_QUERY:-}" || { \
		echo "usage: PARTIAL_COMPLETION_REFERENCE_QUERY='~/path/query' make benchmark-reference" >&2; \
		exit 1; \
	}; \
	test_root=$$(mktemp -d); \
	trap 'rm -rf "$$test_root"' EXIT INT TERM; \
	XDG_CONFIG_HOME="$$test_root/config" \
	XDG_DATA_HOME="$$test_root/data" \
	XDG_STATE_HOME="$$test_root/state" \
	XDG_CACHE_HOME="$$test_root/cache" \
	nvim --headless -i NONE -u tests/minimal_init.lua -l scripts/benchmark_reference.lua

benchmark-reference-selftest:
	@set -eu; \
	test_root=$$(mktemp -d); \
	trap 'rm -rf "$$test_root"' EXIT INT TERM; \
	if env -u PARTIAL_COMPLETION_REFERENCE_QUERY \
		$(MAKE) --no-print-directory benchmark-reference >"$$test_root/query.log" 2>&1; then \
		cat "$$test_root/query.log"; \
		echo "reference benchmark accepted a missing query" >&2; \
		exit 1; \
	fi; \
	rg -q '^usage: PARTIAL_COMPLETION_REFERENCE_QUERY=' "$$test_root/query.log"; \
	mkdir -p "$$test_root/config" "$$test_root/data" "$$test_root/state" "$$test_root/cache"; \
	if PARTIAL_COMPLETION_REFERENCE_QUERY=. PARTIAL_COMPLETION_REFERENCE_RUNS=0 \
		XDG_CONFIG_HOME="$$test_root/config" \
		XDG_DATA_HOME="$$test_root/data" \
		XDG_STATE_HOME="$$test_root/state" \
		XDG_CACHE_HOME="$$test_root/cache" \
		nvim --headless -i NONE -u tests/minimal_init.lua -l scripts/benchmark_reference.lua \
		>"$$test_root/runs.log" 2>&1; then \
		cat "$$test_root/runs.log"; \
		echo "reference benchmark accepted zero runs" >&2; \
		exit 1; \
	fi; \
	rg -q 'must be a positive integer' "$$test_root/runs.log"; \
	echo "Reference benchmark argument self-check passed"

observe-emacs:
	@emacs -Q --batch -l scripts/observe_emacs.el
