#!/bin/sh
set -eu
previous=''; last=''
for argument in "$@"; do previous=$last; last=$argument; done
case "$previous" in
    root@127.0.0.1:/tmp/jzm-e2e/report)
        mkdir -p "$last"
        if [ "$FAKE_MODE" = failure ]; then result=fail; else result=pass; fi
        printf '%s\tfixture\t0\n' "$result" > "$last/results.tsv"
        [ "$FAKE_MODE" = incomplete ] || touch "$last/complete";;
esac
