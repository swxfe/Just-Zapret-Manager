#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
ZM_HOME=$(pwd -P)
JZM_HTTP_PROVIDER=$ZM_HOME/tests/mocks/http-provider.uc
export ZM_HOME JZM_HTTP_PROVIDER
JZM_ASSETS_ARCHIVE=$ZM_HOME/.test-tmp/jzm-assets-fixture.tar.gz
export JZM_ASSETS_ARCHIVE
python3 tools/build-assets.py --fixtures --output "$JZM_ASSETS_ARCHIVE" >/dev/null
exec python3 -B tests/run.py
