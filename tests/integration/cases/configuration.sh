#!/bin/sh
set -eu
# Atomic writes retain permissions without invoking stat, and a failed read cannot publish.
mkdir -p "$ZM_TEST_ROOT/etc/zapret-manager"
modefile=$ZM_TEST_ROOT/etc/zapret-manager/mode-test.txt
printf 'before\n' > "$modefile"
chmod 640 "$modefile"
metadata() {
    ucode -S -e 'import * as fs from "fs"; let s=fs.stat(ARGV[0]); printf("%d %d %d", s.mode, s.uid, s.gid);' -- "$modefile"
}
mode_before=$(metadata)
printf 'after\n' > "$work/mode-input"
sh src/shell/backend.sh state-write "$ZM_TEST_ROOT" zapret "$work/mode-input" mode-test.txt
[ "$(metadata)" = "$mode_before" ]
equal_file "$modefile" "$work/mode-input"
bad sh src/shell/backend.sh state-write "$ZM_TEST_ROOT" zapret "$work/missing-input" mode-test.txt
equal_file "$modefile" "$work/mode-input"
conf=$ZM_TEST_ROOT/etc/config/zapret
hosts=$ZM_TEST_ROOT/opt/zapret/ipset/zapret-hosts-user.txt
printf 'original.example\n' > "$hosts"
cli status | grep -q stopped
cli service start
cli status | grep -q running
ucode -S -L "$ZM_HOME/src/lib" tests/integration/session-cache.uc "$work/manager.json"
# Missing and empty UCI options both mean no strategy, not a read failure.
sh tools/bundle.sh >/dev/null
python3 tests/integration/blockcheck.py "$work/manager.json"
cp "$ZM_TEST_ROOT/service-actions" "$work/noop-actions.before"
cp "$conf" "$work/noop-config.before"
cli config set DISABLE_IPV6 1
bad cli config set NFQWS_PORTS_TCP 999999
equal_file "$conf" "$work/noop-config.before"
equal_file "$ZM_TEST_ROOT/service-actions" "$work/noop-actions.before"
for malformed in '1 ' '1
'; do
    uci -c "$ZM_TEST_ROOT/etc/config" set "zapret.@main[0].DISABLE_IPV6=$malformed"
    uci -c "$ZM_TEST_ROOT/etc/config" commit zapret
    cli config set DISABLE_IPV6 1
    actual=$(cli config get DISABLE_IPV6 && printf x)
    [ "$actual" = "$(printf '1\nx')" ]
done
cp "$conf" "$work/noop-config.before"
# A bad later key cannot leave an earlier batch entry staged or committed.
bad sh src/shell/backend.sh config-set "$ZM_TEST_ROOT" zapret DISABLE_IPV6 0 'bad.key' 1
equal_file "$conf" "$work/noop-config.before"
cp "$conf" "$work/option.before"
uci -c "$ZM_TEST_ROOT/etc/config" delete 'zapret.@main[0].NFQWS_OPT'
uci -c "$ZM_TEST_ROOT/etc/config" commit zapret
printf '0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/empty-option.out"
grep -q '^Стратегии: не выбрана$' "$work/empty-option.out"
uci -c "$ZM_TEST_ROOT/etc/config" set 'zapret.@main[0].NFQWS_OPT='
uci -c "$ZM_TEST_ROOT/etc/config" commit zapret
printf '0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/empty-option.out"
grep -q '^Стратегии: не выбрана$' "$work/empty-option.out"
cp "$work/option.before" "$conf"
cli config set DISABLE_IPV6 0
[ "$(cli config get DISABLE_IPV6)" = 0 ]
# The package submenu hides installation when core files exist; n and Enter cancel removal.
for answer in n ''; do
    printf '1\n2\n%s\n\n0\n0\n' "$answer" | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/cancel.out"
    grep -q '\[y/N\]' "$work/cancel.out"
    if grep -q 'Установить Zapret' "$work/cancel.out"; then exit 1; fi
done
[ -f "$conf" ]
bad cli config set DISABLE_IPV6 2
bad cli config set NFQWS_PORTS_TCP 65536
bad cli config set NFQWS_PORTS_TCP 500-10
cli config set NFQWS_PORTS_TCP 80,443,2000-3000
