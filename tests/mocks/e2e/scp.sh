#!/bin/sh
set -eu
FAKE_ROOT=${E2E_WORKSPACE:-$FAKE_ROOT}
export FAKE_ROOT
previous=''; last=''
for argument in "$@"; do previous=$last; last=$argument; done
case "$previous" in
    root@127.0.0.1:/tmp/jzm-e2e/report)
        mkdir -p "$last"
        if [ "$FAKE_MODE" = failure ]; then result=fail; else result=pass; fi
        : > "$last/results.tsv"
        for name in $E2E_CASES; do
            printf '%s\t%s\t0\n' "$result" "$name" >> "$last/results.tsv"
        done
        [ "$FAKE_MODE" = incomplete ] || touch "$last/complete";;
esac
