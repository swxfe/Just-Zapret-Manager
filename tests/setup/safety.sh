#!/bin/sh
set -eu
ZM_HOME=$(pwd -P)
JZM_HTTP_PROVIDER=$ZM_HOME/tests/mocks/http-provider.uc
export JZM_HTTP_PROVIDER
JZM_REAL_UCODE=$(command -v ucode)
JZM_REAL_MV=$(command -v mv)
JZM_REAL_MKTEMP=$(command -v mktemp)
sandbox=$(mktemp -d /tmp/jzm-safety-XXXXXX)
procd_pid=''
trap 'if [ -n "$procd_pid" ]; then kill "$procd_pid" 2>/dev/null || :; wait "$procd_pid" 2>/dev/null || :; fi; rm -rf -- "$sandbox"' 0
ZM_TEST_ROOT=$sandbox/router
export ZM_HOME ZM_TEST_ROOT JZM_REAL_UCODE JZM_REAL_MV JZM_REAL_MKTEMP
unset ZM_TRANSACTION JZM_BOOTSTRAP JZM_BACKEND
mkdir -p "$sandbox/bin" "$ZM_TEST_ROOT/etc/config" "$ZM_TEST_ROOT/etc/init.d" "$ZM_TEST_ROOT/tmp" "$ZM_TEST_ROOT/usr/bin"
sh tests/setup/procd.sh "$ZM_TEST_ROOT" &
procd_pid=$!
attempt=0
while [ ! -f "$ZM_TEST_ROOT/tmp/procd-ready" ]; do
    attempt=$((attempt + 1)); [ "$attempt" -le 100 ] || exit 1
    sleep 0.01
done
cp tests/mocks/zapret-init.sh "$ZM_TEST_ROOT/etc/init.d/zapret"
chmod +x "$ZM_TEST_ROOT/etc/init.d/zapret"
printf "config main 'main'\n\toption NFQWS_OPT '--filter-tcp=443'\n" > "$ZM_TEST_ROOT/etc/config/zapret"
cp tests/mocks/id.sh "$sandbox/bin/id"
cp tests/mocks/safety/df.sh "$sandbox/bin/df"
cp tests/mocks/safety/mv.sh "$sandbox/bin/mv"
cp tests/mocks/safety/mktemp.sh "$sandbox/bin/mktemp"
cp tests/mocks/safety/ucode.sh "$sandbox/bin/ucode"
chmod +x "$sandbox/bin/"*
cc -shared -fPIC -Wall -Wextra -Werror tests/mocks/faults.c -ldl -o "$sandbox/faults.so"
LD_PRELOAD=$sandbox/faults.so
export LD_PRELOAD
PATH=$sandbox/bin:$PATH
export PATH
bad() { if "$@" > "$sandbox/error" 2>&1; then printf 'expected failure: %s\n' "$*" >&2; exit 1; fi; }
backend() { sh src/shell/backend.sh "$1" "$ZM_TEST_ROOT" zapret "${2:-}" "${3:-}"; }
txn() { sh src/shell/transaction.sh transaction "$ZM_TEST_ROOT" zapret version; }
