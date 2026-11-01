#!/bin/sh
set -eu
case "$1" in
query) printf '%s\n' '[{"name":"zapret","installed-size":1024,"file-size":512}]';;
info) [ -f "$JZM_PACKAGE_TEST/$3" ];;
version) :;;
update) :;;
add|upgrade)
    printf '%s\n' "$*" >> "$JZM_PACKAGE_TEST/actions";;
*) exit 2;;
esac
