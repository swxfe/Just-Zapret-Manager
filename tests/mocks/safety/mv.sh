#!/bin/sh
set -eu
for arg do
    case "$arg" in */etc/zapret-manager/update.json)
        if [ -f "$ZM_TEST_ROOT/fail-update-write" ]; then rm -f "$ZM_TEST_ROOT/fail-update-write"; exit 91; fi;;
    esac
done
exec "$JZM_REAL_MV" "$@"
