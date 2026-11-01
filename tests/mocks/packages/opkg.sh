#!/bin/sh
set -eu
case "$1" in
info) printf 'Size: 1024\n\n';;
status)
    if [ -f "$JZM_PACKAGE_TEST/$2" ]; then printf 'Status: install ok installed\n'; fi;;
list-upgradable)
    [ ! -f "$JZM_PACKAGE_TEST/fail-index" ] || exit 1
    if [ -f "$JZM_PACKAGE_TEST/new-core" ]; then printf 'zapret - 71 - 72\n'; fi;;
update) ;;
install|upgrade)
    printf '%s\n' "$*" >> "$JZM_PACKAGE_TEST/actions"
    shift
    for pkg in "$@"; do
        case "$pkg" in *luci-app-zapret*) touch "$JZM_PACKAGE_TEST/luci-app-zapret";;
            *zapret*) touch "$JZM_PACKAGE_TEST/zapret";; esac
    done;;
*) exit 2;;
esac
