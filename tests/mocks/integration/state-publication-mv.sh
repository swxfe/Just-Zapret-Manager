#!/bin/sh
set -eu
for arg do
    case "$arg" in */etc/zapret-manager/state.json)
        if [ -e "$ZM_TEST_ROOT/fail-state-write" ]; then rm -f "$ZM_TEST_ROOT/fail-state-write"; exit 91; fi;;
    esac
done
exec "$JZM_REAL_MV" "$@"
