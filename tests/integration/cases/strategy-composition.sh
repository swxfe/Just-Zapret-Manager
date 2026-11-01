#!/bin/sh
set -eu
cli source apply flowseal general
check_applied
cp "$ZM_TEST_ROOT/service-actions" "$work/reapply-actions.before"
cli source apply flowseal general
equal_file "$ZM_TEST_ROOT/service-actions" "$work/reapply-actions.before"
cli config get NFQWS_OPT > "$work/flowseal.opts"
grep -q 'quic_initial_steamcommunity_com.bin' "$work/flowseal.opts"
[ "$(grep -c '^#general$' "$work/flowseal.opts")" -eq 1 ]
[ "$(grep -c '^#' "$work/flowseal.opts")" -eq 1 ]
[ "$(grep -c '^--new$' "$work/flowseal.opts")" -eq 2 ]
printf '0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/flowseal-status.out"
grep -q '^Стратегии: general$' "$work/flowseal-status.out"
cli config get NFQWS_PORTS_TCP | grep -q 2802
[ -s "$ZM_TEST_ROOT/opt/zapret/files/fake/quic_initial_steamcommunity_com.bin" ]
cli backup save "$ZM_TEST_ROOT/etc/zapret-manager/backups/labelled-backup.json"
bad cli source compose manager v99 v99
cli source group manager base v99
check_applied
cli config get NFQWS_OPT > "$work/grouped.opts"
grep -q 'hostlist=/opt/zapret/ipset/zapret-hosts-google.txt' "$work/grouped.opts"
[ "$(grep -c '^#general$' "$work/grouped.opts")" -eq 1 ]
[ "$(grep -c '^#v99$' "$work/grouped.opts")" -eq 1 ]
printf '0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/flowseal-status.out"
grep -q '^Стратегии: general + v99$' "$work/flowseal-status.out"
# Group editor performs the same transactions and shows the live composition.
printf '3\n2\n0\n1\n0\n3\n0\n0\n0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/strategy-menu.out"
grep -q 'Базовый трафик:  v99' "$work/strategy-menu.out"
grep -q 'YouTube.*general' "$work/strategy-menu.out"
grep -q 'general (базовый)' "$work/strategy-menu.out"
grep -q 'JZM · Тестирование и автоподбор' "$work/strategy-menu.out"
if grep -q 'Ошибка:' "$work/strategy-menu.out"; then cat "$work/strategy-menu.out"; exit 1; fi
cp "$conf" "$work/cancel-group.before"
printf '3\n2\n1\nd\nn\n0\n0\n0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/cancel-group.out"
equal_file "$conf" "$work/cancel-group.before"
printf '3\n2\n1\nd\ny\n\n0\n0\n0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/disable-group.out"
cli config get NFQWS_OPT > "$work/disabled-group.opts"
if grep -q '^#v99$' "$work/disabled-group.opts"; then exit 1; fi
grep -q '^#general$' "$work/disabled-group.opts"
cli status | grep -q running
# Old ALT9 headings and caches remain usable; games replacement is not a manual edit.
ucode -S -D "file=$ZM_TEST_ROOT/etc/zapret-manager/flowseal.json" -e '
    import * as fs from "fs";
    let data = json(fs.readfile(file));
    data.catalog = replace(data.catalog, "#general\n", "#general_ALT9_\n");
    fs.writefile(file, sprintf("%J\n", data));
'
cli source apply flowseal general_alt9
cli source group manager games Gv1
printf '0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/alt9.out"
grep -q '^Стратегии: general_alt9 + Gv1$' "$work/alt9.out"
cli source remove flowseal
cli config get NFQWS_OPT | grep -q '^#Gv1$'
cli source remove manager games
[ -z "$(uci -c "$ZM_TEST_ROOT/etc/config" -q get 'zapret.@main[0].NFQWS_OPT' || :)" ]
[ "$(cli config get NFQWS_ENABLE)" = 0 ]
cli status | grep -q stopped
# A failed restart restores the empty configuration, disabled nfqws and stopped service.
cp "$conf" "$work/disabled.before"
cp "$statefile" "$work/disabled-state.before"
touch "$ZM_TEST_ROOT/fail-restart"
bad cli source group manager base v99
equal_file "$conf" "$work/disabled.before"
equal_file "$statefile" "$work/disabled-state.before"
cli status | grep -q stopped
cli source group manager base v99
[ "$(cli config get NFQWS_ENABLE)" = 1 ]
cli status | grep -q running
# Restore the original cached name for the following independent scenarios.
ucode -S -D "file=$ZM_TEST_ROOT/etc/zapret-manager/flowseal.json" -e '
    import * as fs from "fs";
    let data = json(fs.readfile(file));
    data.catalog = replace(data.catalog, "#general_ALT9_\n", "#general\n");
    fs.writefile(file, sprintf("%J\n", data));
'
