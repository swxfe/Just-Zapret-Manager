#!/bin/sh
set -eu
printf 'concurrent backup\n' > "$2"
exec "$JZM_REAL_LN" "$@"
