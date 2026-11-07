#!/bin/sh
set -eu
FAKE_ROOT=${E2E_WORKSPACE:-$FAKE_ROOT}
export FAKE_ROOT
for argument in "$@"; do request=$argument; done
case "$request" in
    'echo ready') [ "$FAKE_MODE" != timeout ] && [ -f "$FAKE_ROOT/emulator-pid" ] || exit 255; echo ready;;
    'date -u -s '*" && JZM_E2E_GUEST=1 sh -s") cat > "$FAKE_ROOT/bootstrap-received"; test -s "$FAKE_ROOT/bootstrap-received";;
    'JZM_E2E_GUEST=1 sh /tmp/jzm-e2e-router.sh')
        touch "$FAKE_ROOT/guest-entered"
        if [ "$FAKE_MODE" = signal ]; then
            while kill -0 "$(cat "$FAKE_ROOT/emulator-pid")" 2>/dev/null; do sleep 0.1; done
        fi
        [ "$FAKE_MODE" != failure ];;
esac
