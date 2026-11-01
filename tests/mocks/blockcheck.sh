#!/bin/sh
set -eu
[ ! -f "$ZM_TEST_ROOT/state" ]
[ -t 0 ] && [ -t 1 ]
trap 'exit 130' INT
trap 'exit 143' TERM HUP
printf 'changed by blockcheck\n' > "$ZM_TEST_ROOT/etc/config/zapret"
printf 'JZM_BLOCKCHECK_READY\n'
IFS= read -r answer
[ "$answer" = ready ]
