#!/bin/sh
set -eu
project=$(pwd -P)
# Native package tools are replaced below. Refuse a host with live OpenWrt init
# scripts because the tested helper also refreshes rpcd after installing LuCI.
if [ -e /etc/init.d/rpcd ] || [ -e /etc/init.d/zapret ]; then
    printf '%s\n' 'package tests: skipped on a live OpenWrt host'
    exit 0
fi
stage=$(mktemp -d /tmp/zm-package-test-XXXXXX)
trap 'rm -rf -- "$stage"' 0
mkdir "$stage/bin"
JZM_PACKAGE_TEST=$stage
export JZM_PACKAGE_TEST
cp tests/mocks/id.sh "$stage/bin/id"
cp tests/mocks/packages/opkg.sh "$stage/bin/opkg"
cp tests/mocks/packages/curl.sh "$stage/bin/curl"
cp tests/mocks/packages/unzip.sh "$stage/bin/unzip"
chmod +x "$stage/bin/"*
PATH=$stage/bin:$PATH
export PATH
helper() { sh "$project/src/shell/packages.sh" "$1" '' zapret "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}"; }
