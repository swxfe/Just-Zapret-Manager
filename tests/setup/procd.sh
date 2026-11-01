#!/bin/sh
set -eu
root=$1
project=$(CDPATH='' cd -P "$(dirname "$0")/../.." && pwd)
ucode_bin=${JZM_REAL_UCODE:-$(command -v ucode)}
ubusd_bin=$(dirname "$(readlink -f "$ucode_bin")")/../sbin/ubusd
bus='' provider=''
cleanup() {
    if [ -n "$provider" ]; then kill "$provider" 2>/dev/null || :; wait "$provider" 2>/dev/null || :; fi
    if [ -n "$bus" ]; then kill "$bus" 2>/dev/null || :; wait "$bus" 2>/dev/null || :; fi
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM HUP
# ubusd normally admits root only. A private user namespace maps this test
# user's SO_PEERCRED to uid 0 without changing host permissions or using sudo.
unshare -Ur "$ubusd_bin" -s "$root/tmp/ubus.sock" &
bus=$!
attempt=0
while [ ! -S "$root/tmp/ubus.sock" ]; do
    attempt=$((attempt + 1)); [ "$attempt" -le 100 ] || exit 1
    sleep 0.01
done
"$ucode_bin" -S "$project/tests/mocks/procd.uc" "$root" &
provider=$!
wait "$provider"
