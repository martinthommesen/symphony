.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer e2e e2e-github tui-install tui-test tui-typecheck tui

MIX ?= mix
TUI_DIR ?= ../tui
BUN ?= bun

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, ci"
	@echo "         tui-install, tui-test, tui-typecheck"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

e2e-github:
	SYMPHONY_RUN_LIVE_GITHUB_E2E=1 $(MIX) test test/symphony_elixir/live_github_e2e_test.exs

# ----------------------------------------------------------------------------
# TUI targets. The TUI is a separate Bun project under ../tui. These targets
# are no-ops when Bun is not installed locally so CI can still run the
# Elixir-only path.

tui-install:
	@if [ -d "$(TUI_DIR)" ] && command -v $(BUN) >/dev/null 2>&1; then \
	  cd $(TUI_DIR) && $(BUN) install --silent ; \
	else \
	  echo "[tui-install] skipping: Bun not installed or $(TUI_DIR) missing" ; \
	fi

tui-test: tui-install
	@if [ -d "$(TUI_DIR)" ] && command -v $(BUN) >/dev/null 2>&1; then \
	  cd $(TUI_DIR) && $(BUN) test ; \
	else \
	  echo "[tui-test] skipping: Bun not installed or $(TUI_DIR) missing" ; \
	fi

tui-typecheck: tui-install
	@if [ -d "$(TUI_DIR)" ] && command -v $(BUN) >/dev/null 2>&1; then \
	  cd $(TUI_DIR) && $(BUN) x tsc --noEmit ; \
	else \
	  echo "[tui-typecheck] skipping: Bun not installed or $(TUI_DIR) missing" ; \
	fi

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer
	$(MAKE) tui-typecheck
	$(MAKE) tui-test

all: ci
