SHELL := /bin/sh
.SHELLFLAGS := -eu -c

.PHONY: default check test bundle dist emulator-setup test-e2e

default: bundle

# Shell syntax, ucode compilation and ShellCheck.
check:
	sh tools/check.sh

# Unit, integration, safety and emulator tooling checks.
test:
	sh tests/run.sh

# Build code only after all local checks pass.
bundle: test
	sh tools/bundle.sh

# Share the tested bundle when multiple goals are requested.
dist: bundle
	python3 tools/build-assets.py --output dist/jzm-assets.tar.gz

emulator-setup:
	sh tests/e2e/run.sh setup

test-e2e: dist
	sh tests/e2e/run.sh
