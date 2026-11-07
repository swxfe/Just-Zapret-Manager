SHELL := /bin/sh
.SHELLFLAGS := -eu -c
.DEFAULT_GOAL := bundle
.SUFFIXES:

MAKEFILE_DIR := $(abspath $(dir $(firstword $(MAKEFILE_LIST))))
SHELL_SOURCES := $(shell find src tools tests -type f -name '*.sh')
SHELLCHECK_SOURCES := $(filter-out tests/integration/cases/% tests/e2e/router/% \
    tests/setup/integration.sh tests/setup/packages.sh tests/setup/safety.sh \
    tests/setup/uninstall.sh tests/setup/emulator.sh,$(SHELL_SOURCES))
UCODE_SOURCES := src/main.uc tests/unit/run.uc $(wildcard tests/integration/*.uc \
    tests/performance/*.uc tests/http/*.uc tests/mocks/*.uc tools/*.uc)

.PHONY: default help check check-shell check-ucode check-python check-runtime \
    test bundle dist emulator-setup test-e2e test-matrix clean

# Cleaning and building in the same invocation would race under make -j.
ifneq ($(filter clean,$(MAKECMDGOALS)),)
ifneq ($(words $(MAKECMDGOALS)),1)
$(error Run make clean separately from other goals)
endif
endif

default: bundle

help:
	@printf '%-23s %s\n' \
	    'make [bundle]' 'Test and build the readable JZM bundle' \
	    'make check' 'ShellCheck, shell/Python syntax and ucode compilation' \
	    'make test' 'All local tests, including static checks' \
	    'make dist' 'Test and build code plus the release assets archive' \
	    'make emulator-setup' 'Prepare the OpenWrt emulator' \
	    'make test-e2e' 'Build the release and run all QEMU scenarios' \
	    'make test-matrix' 'Test and build with all three ucode versions' \
	    'make clean' 'Remove dist/ and temporary build/test directories'

check: check-shell check-ucode check-python check-runtime
	@printf '%s\n' 'check: OK'

check-shell:
	@for file in $(SHELL_SOURCES); do sh -n "$$file"; done
	shellcheck --external-sources --check-sourced --shell=sh $(SHELLCHECK_SOURCES)
	@work=$$(mktemp -d /tmp/jzm-check.XXXXXX); \
	trap 'rm -rf -- "$$work"' 0; \
	for payload in bootstrap router; do \
	    sh tests/e2e/run.sh payload "$$payload" > "$$work/$$payload.sh"; \
	    sh -n "$$work/$$payload.sh"; \
	    shellcheck --shell=sh "$$work/$$payload.sh"; \
	done

# Entry programs import the unit/setup/support modules too; leave no uc.out.
check-ucode:
	@for file in $(UCODE_SOURCES); do \
	    ucode -S -L "$(CURDIR)/src/lib" -c -o /dev/null "$$file"; \
	done

check-python:
	python3 -c 'import ast; from pathlib import Path; [ast.parse(p.read_text(), filename=str(p)) for root in ("tests", "tools") for p in Path(root).rglob("*.py")]'

check-runtime:
	JZM_MODE=command sh src/launcher.sh strategy list tests/fixtures/strategies.txt >/dev/null
	@if grep -Ein 'mihomo|magitrickle|netshift|byedpi|tg-ws|amnezia|steer|splify|curl.*\|.*sh|wget.*\|.*sh' \
	    src/launcher.sh src/shell/*.sh src/lib/*.uc src/main.uc data/*.json; then \
	    printf '%s\n' 'check: найден посторонний компонент' >&2; exit 1; \
	fi

# The runner schedules check alongside the independent suites, without repeating it.
test:
	sh tests/run.sh

bundle: test
	ZM_HOME="$(CURDIR)" ucode -S -L "$(CURDIR)/src/lib" tools/bundle.uc

# Shared prerequisites run once, including when multiple goals use make -j.
dist: bundle
	python3 tools/build-assets.py --output dist/jzm-assets.tar.gz

emulator-setup:
	sh tests/e2e/run.sh setup

test-e2e: dist
	sh tests/e2e/run.sh

test-matrix:
	sh tools/test-matrix.sh

# Use names without trailing slashes: remove symlinks, never their targets.
clean:
	@test "$(CURDIR)" = "$(MAKEFILE_DIR)" || { printf '%s\n' 'clean: run make from the project directory (or use make -C)' >&2; exit 1; }
	@test ! -d .emulator/.e2e.lock || { printf '%s\n' 'clean: an E2E run holds the emulator lock' >&2; exit 1; }
	rm -rf -- dist .test-tmp .build-tmp
