#!/bin/sh
set -eu
backend() { /bin/sh "$ZM_HOME/src/shell/backend.sh" "$1" "$ZM_TEST_ROOT" zapret "$JZM_SAFETY_INPUT" "${2:-}"; }
step=${JZM_SAFETY_STEP:-}
if [ "${JZM_NATIVE_ATOM:-0}" = 1 ]; then step=''; fi
case "$step" in
dynamic-abort) backend state-write exported.txt; exit 73;;
asset-abort|asset-commit|asset-reset)
    backend resource-write test.bin
    if [ "$JZM_SAFETY_STEP" = asset-reset ]; then /bin/sh "$ZM_HOME/src/shell/backend.sh" reset "$ZM_TEST_ROOT" zapret; fi
    [ "$JZM_SAFETY_STEP" != asset-abort ] || exit 73
    exit 0;;
manager-abort)
    backend manager-install "$ZM_TEST_ROOT"
    backend manager-config-init "$ZM_TEST_ROOT"
    exit 73;;
update-abort|update-commit)
    backend state-write update.json
    [ "$JZM_SAFETY_STEP" != update-abort ] || exit 73
    exit 0;;
update-signal)
    backend state-write update.json
    : > "$ZM_TEST_ROOT/update-published"
    sleep 2
    exit 0;;
esac
exec "$JZM_REAL_UCODE" "$@"
