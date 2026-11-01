#!/bin/sh
set -eu
cli backup restore "$ZM_TEST_ROOT/etc/zapret-manager/backups/labelled-backup.json"
cli config get NFQWS_OPT > "$work/restored.opts"
equal_file "$work/flowseal.opts" "$work/restored.opts"
# Import is a manager application and records a fresh baseline, even for custom parameters.
sed 's/--filter-l7=discord,stun/--filter-l7=discord/' "$work/flowseal.opts" > "$work/edited.opts"
cli strategy import "$work/edited.opts"
check_applied
cli config get NFQWS_OPT > "$work/imported.opts"
equal_file "$work/edited.opts" "$work/imported.opts"
printf '0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/flowseal-status.out"
grep -q '^Стратегии: general (доступно обновление)$' "$work/flowseal-status.out"
cli backup restore "$ZM_TEST_ROOT/etc/zapret-manager/backups/labelled-backup.json"
check_applied
cp "$statefile" "$work/applied.before"
# A genuine manual edit bypasses the manager; status must not rewrite its baseline.
uci -c "$ZM_TEST_ROOT/etc/config" set "zapret.@main[0].NFQWS_OPT=$(cat "$work/edited.opts")"
uci -c "$ZM_TEST_ROOT/etc/config" commit zapret
printf '0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/manual-status.out"
grep -q '^Стратегии: general (изменена пользователем)$' "$work/manual-status.out"
equal_file "$statefile" "$work/applied.before"
cp "$conf" "$work/manual.before"
for answer in n ''; do
    printf '%s\n' "$answer" | cli source apply flowseal general > "$work/cancel-state.out"
    grep -q 'ваши ручные изменения будут заменены' "$work/cancel-state.out"
    grep -q 'Действие отменено' "$work/cancel-state.out"
    equal_file "$conf" "$work/manual.before"
    equal_file "$statefile" "$work/applied.before"
done
cli source compose manager v99 Yv99 < /dev/null > "$work/cancel-state.out"
equal_file "$conf" "$work/manual.before"
equal_file "$statefile" "$work/applied.before"
cli strategy import "$work/custom.txt" < /dev/null > "$work/cancel-state.out"
equal_file "$conf" "$work/manual.before"
equal_file "$statefile" "$work/applied.before"
# A catalog-only change adds the conflict suffix without changing saved state.
cp "$ZM_TEST_ROOT/etc/zapret-manager/flowseal.json" "$work/catalog.before"
ucode -S -D "file=$ZM_TEST_ROOT/etc/zapret-manager/flowseal.json" -e '
    import * as fs from "fs";
    let data = json(fs.readfile(file));
    data.catalog = replace(data.catalog, "--filter-l7=discord,stun", "--filter-l7=stun");
    fs.writefile(file, sprintf("%J\n", data));
'
printf '0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/conflict-status.out"
grep -q '^Стратегии: general (изменена вами, есть обновление)$' "$work/conflict-status.out"
equal_file "$statefile" "$work/applied.before"
# y authorizes replacing edits; the new application records the updated catalog hash.
printf 'y\n' | cli source apply flowseal general > "$work/accept-state.out"
check_applied
printf '0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/updated-status.out"
grep -q '^Стратегии: general$' "$work/updated-status.out"
cp "$work/catalog.before" "$ZM_TEST_ROOT/etc/zapret-manager/flowseal.json"
cli backup restore "$ZM_TEST_ROOT/etc/zapret-manager/backups/labelled-backup.json"
# Compose also records a complete assembly; a failed state publication rolls UCI back.
cli source compose manager v99 Yv99
check_applied
cp "$conf" "$work/state-write.before"
cp "$statefile" "$work/state-write-state.before"
mkdir -p "$work/fail-state-bin"
cp tests/mocks/integration/state-publication-mv.sh "$work/fail-state-bin/mv"
chmod +x "$work/fail-state-bin/mv"
JZM_REAL_MV=$(command -v mv)
export JZM_REAL_MV
touch "$ZM_TEST_ROOT/fail-state-write"
bad env LD_PRELOAD="$work/faults.so" PATH="$work/fail-state-bin:$PATH" JZM_MODE=command /bin/sh "$ZM_HOME/src/launcher.sh" --config "$work/manager.json" source apply manager v99
equal_file "$conf" "$work/state-write.before"
equal_file "$statefile" "$work/state-write-state.before"
# A worker dying without running ucode catch handlers leaves its stage to the supervisor.
touch "$ZM_TEST_ROOT/crash-state-write"
bad env LD_PRELOAD="$work/faults.so" JZM_MODE=command /bin/sh "$ZM_HOME/src/launcher.sh" --config "$work/manager.json" source apply manager v99
equal_file "$conf" "$work/state-write.before"
equal_file "$statefile" "$work/state-write-state.before"
for staged in "$ZM_TEST_ROOT/etc/zapret-manager/".zm-*; do [ ! -e "$staged" ]; done
cli status | grep -q running
cli backup restore "$ZM_TEST_ROOT/etc/zapret-manager/backups/labelled-backup.json"
cp "$ZM_TEST_ROOT/etc/zapret-manager/flowseal.json" "$work/source.before"
printf 'bad\n' > "$ZM_TEST_ROOT/download"
rm "$ZM_TEST_ROOT/mock-sources"
bad cli source refresh flowseal
equal_file "$ZM_TEST_ROOT/etc/zapret-manager/flowseal.json" "$work/source.before"
