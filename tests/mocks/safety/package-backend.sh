#!/bin/sh
set -eu
case "$1" in
package)
    [ -z "${ZM_TRANSACTION:-}" ] && [ ! -d "$ZM_TEST_ROOT/tmp/zapret-manager.zapret.lock" ] || exit 81
    printf 'Package: zapret\nVersion: 72\nStatus: install ok installed\n' > "$ZM_TEST_ROOT/usr/lib/opkg/status"
    printf "config main 'main'\n\toption NFQWS_OPT '--filter-tcp=444'\n" > "$ZM_TEST_ROOT/etc/config/zapret"
    cp "$ZM_TEST_ROOT/etc/config/zapret" "$ZM_TEST_ROOT/package-config.before"
    : > "$ZM_TEST_ROOT/package-complete";;
transaction) [ -e "$ZM_TEST_ROOT/package-complete" ] || exit 82
    exec /bin/sh "$ZM_HOME/src/shell/backend.sh" "$@";;
*) exec /bin/sh "$ZM_HOME/src/shell/backend.sh" "$@";; esac
