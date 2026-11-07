#!/bin/sh
set -eu
FAKE_ROOT=${E2E_WORKSPACE:-$FAKE_ROOT}
export FAKE_ROOT
printf '%s\n' "$$" > "$FAKE_ROOT/emulator-pid"
while [ "$#" -gt 0 ]; do
    if [ "$1" = -n ]; then
        printf '%s\n' "$2" > "$FAKE_ROOT/flash-path"
        printf changed > "$2/mt7981.mtd0.BL2.bin"
    fi
    shift
done
exec sleep 60
