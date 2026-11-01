#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
ZM_HOME=$(pwd -P)
JZM_HTTP_PROVIDER=$ZM_HOME/tests/mocks/http-provider.uc
export ZM_HOME JZM_HTTP_PROVIDER
sh tests/unit/run.sh
sh tests/integration/run.sh
sh tests/integration/packages.sh
sh tests/safety/transactions.sh
sh tests/safety/uninstall.sh
sh tests/http/run.sh
sh tests/e2e/run.sh selftest
