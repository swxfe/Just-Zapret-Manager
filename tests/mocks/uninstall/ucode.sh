#!/bin/sh
set -eu
if [ "${JZM_NATIVE_ATOM:-0}" != 1 ] && [ -n "${ZM_TRANSACTION:-}" ] && [ -n "${JZM_UNINSTALL_FAULT:-}" ]; then
    sh "$ZM_HOME/src/shell/backend.sh" uninstall-cleanup "$ZM_TEST_ROOT" zapret "${JZM_UNINSTALL_KIND:-manager}"
    if [ "$JZM_UNINSTALL_FAULT" = signal ]; then
        touch "$ZM_TEST_ROOT/cleanup-complete"
        sleep 2
    fi
    exit 73
fi
exec "$JZM_REAL_UCODE" "$@"
