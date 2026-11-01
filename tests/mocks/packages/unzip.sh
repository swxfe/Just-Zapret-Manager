#!/bin/sh
case "$1" in
-l)
    printf '100 2026-01-01 00:00 zapret_72.20260307-r1_arch.ipk\n'
    printf '100 2026-01-01 00:00 apk/zapret-72.20260307-r1.apk\n'
    if [ ! -f "$JZM_PACKAGE_TEST/missing-luci" ]; then
        printf '100 2026-01-01 00:00 luci-app-zapret_72.20260307-r1_all.ipk\n'
        printf '100 2026-01-01 00:00 apk/luci-app-zapret-72.20260307-r1.apk\n'
    fi;;
-p) printf 'Package fixture: %s\n' "$3";;
*) exit 2;;
esac
