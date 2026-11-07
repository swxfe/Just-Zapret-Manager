#!/bin/sh
set -eu
# A missing packaged dependency must fail offline, without fetching a replacement.
dependency=$(cli strategy show general | sed -n '/^--.*=\/opt\/zapret\/fakes\//s/^[^=]*=//p' | head -n 1)
[ -n "$dependency" ]
mv "$ZM_TEST_ROOT$dependency" "$work/missing-v1-fake"
bad cli strategy apply general
mv "$work/missing-v1-fake" "$ZM_TEST_ROOT$dependency"
[ ! -e "$statefile" ]
equal_file "$conf" "$work/conf.before"
printf '%s\n' '--filter-tcp=443' '--dpi-desync=multisplit' > "$work/custom.txt"
cli strategy validate "$work/custom.txt" > "$work/validated.txt"
equal_file "$work/custom.txt" "$work/validated.txt"
cp "$conf" "$work/first-apply.before"
touch "$ZM_TEST_ROOT/fail-restart"
bad cli strategy import "$work/custom.txt"
[ ! -e "$statefile" ]
equal_file "$conf" "$work/first-apply.before"
cli strategy import "$work/custom.txt"
check_applied
cli config get NFQWS_OPT | grep -q multisplit
# The public entry opens a menu; selecting a service or setting delegates to the same transactions.
printf '2\n1\n\n0\n6\n2\n1\n\n0\n0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/menu-actions.out"
cli status | grep -q running
[ "$(cli config get DISABLE_IPV6)" = 0 ]
