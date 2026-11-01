#!/bin/sh
set -eu
printf 'https://one.test/\nhttps://two.test/\n' > "$work/urls.txt"
printf '#slow\n--dpi-desync=fake\n#fast\n--dpi-desync=multisplit\n' > "$work/catalog.txt"
cp "$conf" "$work/benchmark.before"
cp "$statefile" "$work/benchmark-state.before"
cli benchmark "$work/urls.txt" "$work/catalog.txt" > "$work/results"
equal_file "$conf" "$work/benchmark.before"
equal_file "$statefile" "$work/benchmark-state.before"
cli status | grep -q running
cli service stop
cli benchmark "$work/urls.txt" "$work/catalog.txt" > "$work/results"
equal_file "$conf" "$work/benchmark.before"
equal_file "$statefile" "$work/benchmark-state.before"
cli status | grep -q stopped
cli auto-best "$work/urls.txt" "$work/catalog.txt" > "$work/results"
cli config get NFQWS_OPT | grep -q multisplit
cli status | grep -q running
cli test "$work/urls.txt" > "$work/results"
cli service stop
bad cli test "$work/urls.txt"
mkdir "$ZM_TEST_ROOT/tmp/zapret-manager.zapret.lock"
bad cli service start
rmdir "$ZM_TEST_ROOT/tmp/zapret-manager.zapret.lock"
bad cli install
cli status | grep -q stopped
