#!/bin/sh
set -eu
project=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd)
# The Python test runner owns concurrency; do not inherit a closed Make jobserver.
MAKEFLAGS='' MFLAGS='' exec make --no-print-directory -C "$project" check
