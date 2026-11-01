#!/bin/sh
set -eu
cli hosts user add Example.com example.com sub.example.com
[ "$(grep -c '^example.com$' "$hosts")" -eq 1 ]
cli hosts user remove example.com
if grep -q '^example.com$' "$hosts"; then exit 1; fi
cp "$hosts" "$work/hosts.before"
bad cli hosts user add 'example.com;touch /tmp/never'
equal_file "$hosts" "$work/hosts.before"
printf 'REFRESHED.example\nrefreshed.example\n' > "$ZM_TEST_ROOT/download"
cli hosts exclude refresh
[ "$(cat "$ZM_TEST_ROOT/opt/zapret/ipset/zapret-hosts-user-exclude.txt")" = refreshed.example ]
cli backup save "$ZM_TEST_ROOT/etc/zapret-manager/backups/backup.json"
cp "$conf" "$work/conf.before"
cli config set DISABLE_IPV6 1
cli hosts user add added.example
cli backup restore "$ZM_TEST_ROOT/etc/zapret-manager/backups/backup.json"
equal_file "$conf" "$work/conf.before"
equal_file "$hosts" "$work/hosts.before"
# Stock Zapret lists include addresses, CIDRs, single suffixes and comments.
exclude=$ZM_TEST_ROOT/opt/zapret/ipset/zapret-hosts-user-exclude.txt
cp "$exclude" "$work/exclude.before"
printf '# upstream package defaults\n127.0.0.0/8\n10.0.0.0/8\n::1\nfc00::/7\nru\nрф\nexample.com\n' > "$exclude"
cp "$exclude" "$work/exclude.mixed"
cli backup save "$ZM_TEST_ROOT/etc/zapret-manager/backups/mixed-lists.json"
printf 'changed.example\n' > "$exclude"
cli backup restore "$ZM_TEST_ROOT/etc/zapret-manager/backups/mixed-lists.json"
equal_file "$exclude" "$work/exclude.mixed"
cp "$work/exclude.before" "$exclude"
# Uppercase Y accepts the same confirmation through the public menu.
printf '7\n2\n%s\nY\n\n0\n0\n' "$ZM_TEST_ROOT/etc/zapret-manager/backups/backup.json" | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/confirm.out"
if grep -q 'Ошибка:' "$work/confirm.out"; then cat "$work/confirm.out"; exit 1; fi
equal_file "$conf" "$work/conf.before"
bad cli backup save "$ZM_TEST_ROOT/etc/zapret-manager/backups/backup.json"
# A competing backup appearing between preflight and link publication is preserved.
mkdir -p "$work/race-bin"
JZM_REAL_LN=$(command -v ln)
export JZM_REAL_LN
cp tests/mocks/integration/backup-race-ln.sh "$work/race-bin/ln"
chmod +x "$work/race-bin/ln"
race_backup=$ZM_TEST_ROOT/etc/zapret-manager/backups/concurrent.json
bad env PATH="$work/race-bin:$PATH" JZM_MODE=command sh src/launcher.sh --config "$work/manager.json" backup save "$race_backup"
[ "$(cat "$race_backup")" = 'concurrent backup' ]
for staged in "$ZM_TEST_ROOT/etc/zapret-manager/backups/".zm-*; do [ ! -e "$staged" ]; done
printf '{"format":1,"profile":"other"}\n' > "$work/wrong.json"
bad cli backup restore "$work/wrong.json"
equal_file "$conf" "$work/conf.before"
touch "$ZM_TEST_ROOT/fail-restart"
bad cli config set DISABLE_IPV6 1
equal_file "$conf" "$work/conf.before"
cli status | grep -q running
touch "$ZM_TEST_ROOT/fail-restart"
bad cli hosts user add rollback.example
equal_file "$hosts" "$work/hosts.before"
