#!/bin/sh
set -eu
cli source apply flowseal general
check_applied
cp "$ZM_TEST_ROOT/service-actions" "$work/reapply-actions.before"
cli source apply flowseal general
equal_file "$ZM_TEST_ROOT/service-actions" "$work/reapply-actions.before"
cli config get NFQWS_OPT > "$work/flowseal.opts"
grep -q 'ACTIVE_DISCORD_UDP.bin' "$work/flowseal.opts"
[ "$(grep -c '^#general$' "$work/flowseal.opts")" -eq 1 ]
[ "$(grep -c '^#' "$work/flowseal.opts")" -eq 1 ]
[ "$(grep -c '^--new$' "$work/flowseal.opts")" -eq 4 ]
printf '0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/flowseal-status.out"
grep -q '^Стратегии: general$' "$work/flowseal-status.out"
cli config get NFQWS_PORTS_TCP | grep -q 1024-65535
[ -s "$ZM_TEST_ROOT/opt/zapret/fakes/ACTIVE_DISCORD_UDP.bin" ]
cli backup save "$ZM_TEST_ROOT/etc/zapret-manager/backups/labelled-backup.json"
cli source group manager games Gv1
# A complete Flowseal preset blocks the composer without changing live state.
cp "$conf" "$work/blocked-compose-conf.before"
cp "$statefile" "$work/blocked-compose-state.before"
cp "$ZM_TEST_ROOT/service-actions" "$work/blocked-compose-actions.before"
printf '3\n2\n\n6\nn\n0\n0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/blocked-compose.out"
grep -q 'Сначала очистите текущую стратегию Flowseal' "$work/blocked-compose.out"
grep -q '6. Очистить стратегию' "$work/blocked-compose.out"
if grep -q 'JZM · Собрать стратегию' "$work/blocked-compose.out"; then exit 1; fi
equal_file "$conf" "$work/blocked-compose-conf.before"
equal_file "$statefile" "$work/blocked-compose-state.before"
equal_file "$ZM_TEST_ROOT/service-actions" "$work/blocked-compose-actions.before"
# Clearing is transactional even when stopping the service partially fails.
touch "$ZM_TEST_ROOT/fail-stop"
bad cli strategy clear
equal_file "$conf" "$work/blocked-compose-conf.before"
equal_file "$statefile" "$work/blocked-compose-state.before"
cli status | grep -q running
# The explicit clear button unlocks the composer in the same menu session.
printf '3\n6\ny\n\n2\n0\n0\n0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/clear-strategy.out"
grep -q 'Стратегия очищена' "$work/clear-strategy.out"
grep -q 'JZM · Собрать стратегию' "$work/clear-strategy.out"
if grep -q 'Ошибка:' "$work/clear-strategy.out"; then cat "$work/clear-strategy.out"; exit 1; fi
[ -z "$(uci -c "$ZM_TEST_ROOT/etc/config" -q get 'zapret.@main[0].NFQWS_OPT' || :)" ]
[ "$(cli config get NFQWS_ENABLE)" = 0 ]
cli status | grep -q stopped
check_applied
cp "$conf" "$work/clear-conf.before"
cp "$statefile" "$work/clear-state.before"
cp "$ZM_TEST_ROOT/service-actions" "$work/clear-actions.before"
cli strategy clear
equal_file "$conf" "$work/clear-conf.before"
equal_file "$statefile" "$work/clear-state.before"
equal_file "$ZM_TEST_ROOT/service-actions" "$work/clear-actions.before"
cli source apply flowseal general
bad cli source compose flowseal base_general base_general
cli source group flowseal base base_general
check_applied
cli config get NFQWS_OPT > "$work/grouped.opts"
grep -q 'hostlist=/opt/zapret/ipset/zapret-hosts-google.txt' "$work/grouped.opts"
[ "$(grep -c '^#general$' "$work/grouped.opts")" -eq 1 ]
[ "$(grep -c '^#base_general$' "$work/grouped.opts")" -eq 1 ]
printf '0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/flowseal-status.out"
grep -q '^Стратегии: general + base_general$' "$work/flowseal-status.out"
# Clear Flowseal before composing independent groups; unrelated YouTube stays intact.
cli source remove flowseal
cli source group manager youtube Yv99
# Group editor performs the same transactions and shows the live composition.
printf '3\n2\n0\n1\n0\n3\n0\n0\n0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/strategy-menu.out"
grep -q 'Базовый трафик:  base_general' "$work/strategy-menu.out"
grep -q 'YouTube.*Yv99' "$work/strategy-menu.out"
grep -q 'general (базовый)' "$work/strategy-menu.out"
grep -q 'JZM · Тестирование и автоподбор' "$work/strategy-menu.out"
if grep -q 'Ошибка:' "$work/strategy-menu.out"; then cat "$work/strategy-menu.out"; exit 1; fi
# Games are a direct strategy-menu entry and absent from the composer.
printf '3\n4\n0\n0\n0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/games-menu.out"
grep -q 'JZM · Выбор · Игры' "$work/games-menu.out"
if grep -q 'Игры:' "$work/strategy-menu.out"; then exit 1; fi
cp "$conf" "$work/cancel-group.before"
printf '3\n2\n1\nd\nn\n0\n0\n0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/cancel-group.out"
equal_file "$conf" "$work/cancel-group.before"
printf '3\n2\n1\nd\ny\n\n0\n0\n0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/disable-group.out"
cli config get NFQWS_OPT > "$work/disabled-group.opts"
if grep -q '^#base_general$' "$work/disabled-group.opts"; then exit 1; fi
grep -q '^#Yv99$' "$work/disabled-group.opts"
cli status | grep -q running
# Old ALT9 headings and caches remain usable; games replacement is not a manual edit.
ucode -S -D "file=$ZM_TEST_ROOT/etc/zapret-manager/assets/catalogs/flowseal.json" -e '
    import * as fs from "fs";
    let data = json(fs.readfile(file));
    data.catalog = replace(data.catalog, "#general\n", "#general_ALT9_\n");
    fs.writefile(file, sprintf("%J\n", data));
'
cli source apply flowseal general_alt9
cli source group flowseal games games_general
printf '0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/alt9.out"
grep -q '^Стратегии: general_alt9 + games_general$' "$work/alt9.out"
cli source remove flowseal
cli config get NFQWS_OPT | grep -q '^#games_general$'
cli source remove flowseal games
[ -z "$(uci -c "$ZM_TEST_ROOT/etc/config" -q get 'zapret.@main[0].NFQWS_OPT' || :)" ]
[ "$(cli config get NFQWS_ENABLE)" = 0 ]
cli status | grep -q stopped
# A failed restart restores the empty configuration, disabled nfqws and stopped service.
cp "$conf" "$work/disabled.before"
cp "$statefile" "$work/disabled-state.before"
touch "$ZM_TEST_ROOT/fail-restart"
bad cli source group flowseal base base_general
equal_file "$conf" "$work/disabled.before"
equal_file "$statefile" "$work/disabled-state.before"
cli status | grep -q stopped
cli source group flowseal base base_general
[ "$(cli config get NFQWS_ENABLE)" = 1 ]
cli status | grep -q running
# Restore the original cached name for the following independent scenarios.
ucode -S -D "file=$ZM_TEST_ROOT/etc/zapret-manager/assets/catalogs/flowseal.json" -e '
    import * as fs from "fs";
    let data = json(fs.readfile(file));
    data.catalog = replace(data.catalog, "#general_ALT9_\n", "#general\n");
    fs.writefile(file, sprintf("%J\n", data));
'
