#!/bin/sh
set -eu
template=''
for argument do template=$argument; done
case "$template" in *XXXXXX) ;; *) printf 'mktemp: invalid BusyBox template: %s\n' "$template" >&2; exit 1;; esac
exec "$JZM_REAL_MKTEMP" "$@"
