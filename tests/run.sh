#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
ZM_HOME=$(pwd -P)
export ZM_HOME
for tool in ucode uci sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'test: нужен %s\n' "$tool" >&2; exit 1; }
done
ucode -S -L "$ZM_HOME/src/lib" tests/unit.uc
work=$(mktemp -d "${TMPDIR:-/tmp}/zm-integration-XXXXXX")
trap 'rm -rf -- "$work"' 0
ZM_TEST_ROOT=$work/router
export ZM_TEST_ROOT
mkdir -p "$ZM_TEST_ROOT/etc/config" "$ZM_TEST_ROOT/etc/init.d" "$ZM_TEST_ROOT/opt/zapret/ipset" "$ZM_TEST_ROOT/tmp" "$work/bin"
cat > "$ZM_TEST_ROOT/etc/config/zapret" <<'EOF'
config main 'main'
    option NFQWS_OPT '--dpi-desync=fake'
    option DISABLE_IPV6 '1'
    option NFQWS_PORTS_TCP '80,443'
EOF
cp tests/mock-init.sh "$ZM_TEST_ROOT/etc/init.d/zapret"
cp tests/mock-cron.sh "$ZM_TEST_ROOT/etc/init.d/cron"
cp tests/mock-firewall.sh "$ZM_TEST_ROOT/etc/init.d/firewall"
cp tests/mock-curl.sh "$work/bin/curl"
# Only the temporary fixture sees this privilege shim; no host paths are passed to mutations.
printf '#!/bin/sh\nprintf "0\\n"\n' > "$work/bin/id"
# Some OpenWrt images omit the stat applet. All writes and rollback must work without it.
printf '#!/bin/sh\nprintf "unexpected external stat call\\n" >&2\nexit 127\n' > "$work/bin/stat"
chmod +x "$ZM_TEST_ROOT/etc/init.d/"* "$work/bin/"*
PATH=$work/bin:$PATH
export PATH
ucode -S -L "$ZM_HOME/src/lib" -D "fixture=$ZM_TEST_ROOT" -D "destination=$work/manager.json" -e '
    import { writefile, readfile } from "fs";
    let c = json(readfile("data/manager.json"));
    c.root = fixture;
    c.updater.repo = "";
    c.settle_seconds = 0;
    writefile(destination, sprintf("%J\n", c));
'
if [ "${JZM_TEST_BUNDLE:-0}" = 1 ]; then sh tools/bundle.sh >/dev/null; fi
cli() {
    if [ "${JZM_TEST_BUNDLE:-0}" = 1 ]; then
        JZM_MODE='command' sh "$ZM_HOME/dist/just-zapret-manager.sh" --config "$work/manager.json" "$@"
    else
        JZM_MODE='command' sh "$ZM_HOME/src/launcher.sh" --config "$work/manager.json" "$@"
    fi
}
statefile=$ZM_TEST_ROOT/etc/zapret-manager/state.json
check_applied() {
    ucode -S -L "$ZM_HOME/src/lib" -D "cfg=$work/manager.json" -e '
        import { settings } from "settings";
        import { configured_strategy } from "status";
        import { read_applied, strategy_hash } from "applied";
        let ctx = settings(getenv("ZM_HOME"), cfg), state = read_applied(ctx);
        assert(state != null && state.applied_hash == strategy_hash(configured_strategy(ctx)), "persist exact UCI hash");
        assert(state.applied_at > 0, "persist application timestamp");
    '
}
bad() {
    if "$@" > "$work/error" 2>&1; then
        printf 'expected failure: %s\n' "$*" >&2
        exit 1
    fi
}
equal_file() { cmp "$1" "$2" || { printf 'files differ: %s %s\n' "$1" "$2" >&2; exit 1; }; }
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
# Missing and empty UCI options both mean no strategy, not a read failure.
sh tools/bundle.sh >/dev/null
sh tests/blockcheck.sh "$work/manager.json"
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
bad cli strategy apply v1
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
# Upstream catalogs are parsed as data, stored atomically and applied with required resources.
touch "$ZM_TEST_ROOT/mock-sources"
cli source refresh manager > "$work/source.out"
cli source list manager | grep -q '^v99$'
cli source refresh flowseal > "$work/source.out"
cli source list flowseal | grep -q '^general$'
# API failures must explain themselves and preserve catalogs, UCI and service state.
cp "$ZM_TEST_ROOT/etc/zapret-manager/manager.json" "$work/api-manager.before"
cp "$ZM_TEST_ROOT/etc/zapret-manager/flowseal.json" "$work/api-flowseal.before"
cp "$conf" "$work/api-conf.before"
for kind in primary secondary throttled forbidden unavailable transport; do
    printf '403\n' > "$ZM_TEST_ROOT/api-status"
    printf '59\n' > "$ZM_TEST_ROOT/api-remaining"
    printf '{"message":"Resource not accessible"}' > "$ZM_TEST_ROOT/api-body"
    case "$kind" in
        primary) printf '0\n' > "$ZM_TEST_ROOT/api-remaining";;
        secondary) printf '{"message":"You have exceeded a secondary rate limit."}' > "$ZM_TEST_ROOT/api-body";;
        throttled) printf '429\n' > "$ZM_TEST_ROOT/api-status";;
        unavailable) printf '503\n' > "$ZM_TEST_ROOT/api-status"; printf '<html>Unavailable</html>' > "$ZM_TEST_ROOT/api-body";;
        transport) touch "$ZM_TEST_ROOT/api-transport-fail";;
    esac
    for command in 'source refresh manager' 'source refresh flowseal' 'install-upstream'; do
        # These fixed test commands deliberately expand into separate arguments.
        # shellcheck disable=SC2086
        bad cli $command
        case "$kind" in
            primary|secondary|throttled) grep -Fq 'Превышен лимит запросов GitHub API (60/час на ваш IP)' "$work/error";;
            forbidden) grep -Fq 'GitHub API: ошибка HTTP 403' "$work/error";;
            unavailable) grep -Fq 'GitHub API: ошибка HTTP 503' "$work/error";;
            transport) grep -Fq 'github-download: код завершения 28' "$work/error";;
        esac
        equal_file "$conf" "$work/api-conf.before"
        equal_file "$ZM_TEST_ROOT/etc/zapret-manager/manager.json" "$work/api-manager.before"
        equal_file "$ZM_TEST_ROOT/etc/zapret-manager/flowseal.json" "$work/api-flowseal.before"
        cli status | grep -q running
        [ ! -d "$ZM_TEST_ROOT/tmp/zapret-manager.zapret.lock" ]
    done
done
rm -f "$ZM_TEST_ROOT/api-status" "$ZM_TEST_ROOT/api-remaining" "$ZM_TEST_ROOT/api-body" "$ZM_TEST_ROOT/api-transport-fail"
printf '%s\n' 'sources: 18 API failures preserve catalogs, configuration and service state'
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
cat > "$work/fail-state-bin/mv" <<'EOF'
#!/bin/sh
set -eu
for arg do
    case "$arg" in */etc/zapret-manager/state.json)
        if [ -e "$ZM_TEST_ROOT/fail-state-write" ]; then rm -f "$ZM_TEST_ROOT/fail-state-write"; exit 91; fi;;
    esac
done
exec "$JZM_REAL_MV" "$@"
EOF
chmod +x "$work/fail-state-bin/mv"
JZM_REAL_MV=$(command -v mv)
export JZM_REAL_MV
touch "$ZM_TEST_ROOT/fail-state-write"
bad env PATH="$work/fail-state-bin:$PATH" JZM_MODE=command /bin/sh "$ZM_HOME/src/launcher.sh" --config "$work/manager.json" source apply manager v99
equal_file "$conf" "$work/state-write.before"
equal_file "$statefile" "$work/state-write-state.before"
cli status | grep -q running
cli backup restore "$ZM_TEST_ROOT/etc/zapret-manager/backups/labelled-backup.json"
cp "$ZM_TEST_ROOT/etc/zapret-manager/flowseal.json" "$work/source.before"
printf 'bad\n' > "$ZM_TEST_ROOT/download"
rm "$ZM_TEST_ROOT/mock-sources"
bad cli source refresh flowseal
equal_file "$ZM_TEST_ROOT/etc/zapret-manager/flowseal.json" "$work/source.before"
# Device exclusions and firewall compatibility changes have their own rollback snapshots.
printf '1 00:11:22:33:44:55 192.168.1.20 laptop *\n' > "$ZM_TEST_ROOT/tmp/dhcp.leases"
cli devices add 192.168.1.20
cp "$conf" "$work/device-add.before"
cp "$ZM_TEST_ROOT/etc/zapret-manager/devices.txt" "$work/device-list.before"
cli devices add 192.168.1.20
equal_file "$conf" "$work/device-add.before"
equal_file "$ZM_TEST_ROOT/etc/zapret-manager/devices.txt" "$work/device-list.before"
cli devices remove 192.168.1.20
cli devices remove 192.168.1.20
cli devices toggle 192.168.1.20
cli devices list | grep -q 'Исключён 192.168.1.20'
hook=$ZM_TEST_ROOT/opt/zapret/init.d/openwrt/custom.d/20-jzm-exclude.sh
sh -n "$hook"
grep -q '^set -eu$' "$hook"
shellcheck --shell=sh "$hook"
# Upstream sources hooks before creating chains and during shutdown too.
cat > "$work/check-hook.sh" <<'EOF'
#!/bin/sh
set -eu
hook=$1
hooklog=$2
case "$3" in relaxed) set +eu;; strict) :;; *) exit 2;; esac
nft() {
    case "$1" in
        -a)
            [ "$ready" = 1 ] || return 1
            if [ -s "$hooklog" ]; then printf '%s\n' 'comment "jzm_devices"'; fi
            ;;
        insert) printf '%s\n' "$*" >> "$hooklog";;
        *) return 2;;
    esac
}
options=$-
. "$hook"
[ "$-" = "$options" ] || exit 1
[ ! -e "$hooklog" ] || exit 1
ready=0
if zapret_custom_firewall_nft; then exit 1; fi
[ ! -e "$hooklog" ] || exit 1
ready=1
zapret_custom_firewall_nft || exit 1
zapret_custom_firewall_nft || exit 1
[ "$(wc -l < "$hooklog")" -eq 1 ] || exit 1
grep -q '192.168.1.20' "$hooklog" || exit 1
EOF
for mode in relaxed strict; do
    sh "$work/check-hook.sh" "$hook" "$work/hook-$mode.log" "$mode"
done
cp "$hook" "$work/hook.before"
touch "$ZM_TEST_ROOT/fail-restart"
bad cli devices toggle 192.168.1.21
equal_file "$hook" "$work/hook.before"
cli devices clear
# Recognized legacy exclusions migrate without executing their old shell file.
legacy=$ZM_TEST_ROOT/opt/zapret/init.d/openwrt/custom.d/20-script.sh
cat > "$legacy" <<'EOF'
EXCEPT_SRC='{ 192.168.1.30 }'
nft insert rule inet zapret postrouting_hook index 0 \
  ip saddr $EXCEPT_SRC meta mark set meta mark \| 0x40000000
EOF
cp "$legacy" "$work/legacy.before"
touch "$ZM_TEST_ROOT/fail-restart"
bad cli devices toggle 192.168.1.31
equal_file "$legacy" "$work/legacy.before"
cli devices toggle 192.168.1.31
[ ! -e "$legacy" ]
equal_file "$ZM_TEST_ROOT/etc/zapret-manager/legacy-exclusion-hook.sh" "$work/legacy.before"
cli devices list | grep -q 'Исключён 192.168.1.30'
cli devices clear
cat > "$ZM_TEST_ROOT/etc/config/firewall" <<'EOF'
config defaults
    option flow_offloading '1'
    option flow_offloading_hw '0'
config rule 'unrelated'
    option name 'preserved'
EOF
cli network offload disable
[ "$(tail -n 1 "$ZM_TEST_ROOT/firewall-actions")" = restart ]
[ "$(uci -c "$ZM_TEST_ROOT/etc/config" get 'firewall.@defaults[0].flow_offloading')" = 0 ]
cli network offload restore
[ "$(uci -c "$ZM_TEST_ROOT/etc/config" get 'firewall.@defaults[0].flow_offloading')" = 1 ]
cli network quic on
[ "$(tail -n 1 "$ZM_TEST_ROOT/firewall-actions")" = reload ]
[ "$(uci -c "$ZM_TEST_ROOT/etc/config" get firewall.jzm_quic.name)" = JZM_Block_QUIC ]
cli network quic off
[ "$(uci -c "$ZM_TEST_ROOT/etc/config" get firewall.unrelated.name)" = preserved ]
cp "$ZM_TEST_ROOT/etc/config/firewall" "$work/firewall.before"
touch "$ZM_TEST_ROOT/fail-firewall"
bad cli network quic on
[ "$(tail -n 1 "$ZM_TEST_ROOT/firewall-actions")" = reload ]
equal_file "$ZM_TEST_ROOT/etc/config/firewall" "$work/firewall.before"
printf 'https://one.test/\nhttps://two.test/\n' > "$work/urls.txt"
printf '#slow\n--dpi-desync=fake\n#fast\n--dpi-desync=multisplit\n' > "$work/catalog.txt"
cp "$conf" "$work/benchmark.before"
cp "$statefile" "$work/benchmark-state.before"
cli benchmark "$work/urls.txt" "$work/catalog.txt" > "$work/results"
equal_file "$conf" "$work/benchmark.before"
equal_file "$statefile" "$work/benchmark-state.before"
cli status | grep -q running
cli service stop
cli benchmark "$work/urls.txt" "$work/catalog.txt" > "$work/results"
equal_file "$conf" "$work/benchmark.before"
equal_file "$statefile" "$work/benchmark-state.before"
cli status | grep -q stopped
cli auto-best "$work/urls.txt" "$work/catalog.txt" > "$work/results"
cli config get NFQWS_OPT | grep -q multisplit
cli status | grep -q running
cli test "$work/urls.txt" > "$work/results"
cli service stop
bad cli test "$work/urls.txt"
mkdir "$ZM_TEST_ROOT/tmp/zapret-manager.zapret.lock"
bad cli service start
rmdir "$ZM_TEST_ROOT/tmp/zapret-manager.zapret.lock"
bad cli install
cli status | grep -q stopped
# Verify that the standalone artifact runs away from the source tree.
sh tools/bundle.sh >/dev/null
cp dist/just-zapret-manager.sh "$work/standalone.sh"
# Automated installation uses the same internal protocol as other mutations.
DESTDIR=$work/internal-image JZM_MODE='command' sh "$work/standalone.sh" --config "$work/manager.json" manager-install > "$work/internal-install.log"
equal_file "$work/standalone.sh" "$work/internal-image/usr/bin/jzm"
[ -x "$work/internal-image/usr/bin/jzm" ]
bad sh "$work/standalone.sh" manager-install
# Show exact package versions and known configured profiles, with independent service state.
mkdir -p "$ZM_TEST_ROOT/usr/lib/opkg"
cat > "$ZM_TEST_ROOT/usr/lib/opkg/status" <<'EOF'
Package: zapret
Version: 72.20260307-r1
Status: install ok installed

Package: luci-app-zapret
Version: 72.20260307-r1
Status: install ok installed
EOF
touch "$ZM_TEST_ROOT/mock-release"
cp "$conf" "$work/no-update.before"
cli update-upstream > "$work/no-update.out"
grep -q 'Новых версий нет' "$work/no-update.out"
equal_file "$conf" "$work/no-update.before"
rm "$ZM_TEST_ROOT/mock-release"
cli strategy apply v3 Yv08
printf '0\n' | JZM_CONFIG=$work/manager.json sh "$work/standalone.sh" > "$work/dashboard.out"
grep -q 'установлен · 72.20260307-r1' "$work/dashboard.out"
if grep -q 'LuCI Zapret:' "$work/dashboard.out"; then exit 1; fi
grep -q 'Yv08' "$work/dashboard.out"
grep -q 'v3' "$work/dashboard.out"
mkdir -p "$ZM_TEST_ROOT/bin"
cat > "$ZM_TEST_ROOT/bin/ubus" <<'EOF'
#!/bin/sh
set -eu
[ "$*" = '-t 1 call service list {"name":"zapret"}' ]
printf '%s\n' '{"zapret":{"instances":{"nfqws":{"running":true}}}}'
EOF
chmod +x "$ZM_TEST_ROOT/bin/ubus"
mv "$ZM_TEST_ROOT/etc/init.d/zapret" "$work/init-procd.saved"
printf '#!/bin/sh\nexit 99\n' > "$ZM_TEST_ROOT/etc/init.d/zapret"
chmod +x "$ZM_TEST_ROOT/etc/init.d/zapret"
printf '0\n' | JZM_CONFIG=$work/manager.json sh "$work/standalone.sh" > "$work/procd.out"
grep -q '^Сервис: запущен$' "$work/procd.out"
printf '#!/bin/sh\nprintf "invalid\\n"\n' > "$ZM_TEST_ROOT/bin/ubus"
printf '0\n' | JZM_CONFIG=$work/manager.json sh "$work/standalone.sh" > "$work/procd-error.out"
grep -q '^Сервис: не удалось проверить$' "$work/procd-error.out"
rm "$ZM_TEST_ROOT/bin/ubus"
mv "$work/init-procd.saved" "$ZM_TEST_ROOT/etc/init.d/zapret"
printf '0\n' | JZM_COLOR=always JZM_CONFIG=$work/manager.json sh "$work/standalone.sh" > "$work/colors.out"
grep -q "$(printf '\033')\[32" "$work/colors.out"
# No installed files or package database: only installation is offered.
mv "$ZM_TEST_ROOT/etc/init.d/zapret" "$work/init.saved"
mv "$ZM_TEST_ROOT/usr/lib/opkg/status" "$work/status.saved"
printf '1\n0\n0\n' | JZM_CONFIG=$work/manager.json sh "$work/standalone.sh" > "$work/not-installed.out"
grep -q 'Установить Zapret' "$work/not-installed.out"
if grep -q 'Обновить Zapret\|Удалить Zapret' "$work/not-installed.out"; then exit 1; fi
mv "$work/init.saved" "$ZM_TEST_ROOT/etc/init.d/zapret"
mv "$work/status.saved" "$ZM_TEST_ROOT/usr/lib/opkg/status"
# Startup must not call extraction/temporary-directory helpers, even when they fail.
mkdir "$work/startup-bin"
for helper in mktemp tar base64 gzip; do
    printf '#!/bin/sh\nexit 99\n' > "$work/startup-bin/$helper"
    chmod +x "$work/startup-bin/$helper"
done
printf '0\n' | PATH=$work/startup-bin:$PATH JZM_CONFIG=$work/manager.json sh "$work/standalone.sh" > "$work/startup.out"
grep -q 'источник не настроен' "$work/startup.out"
printf '0\n' | JZM_CONFIG=$work/manager.json sh "$work/standalone.sh" > "$work/menu.out"
grep -q 'Установка / обновление / удаление' "$work/menu.out"
bad sh "$work/standalone.sh" help
# The payload does not reread $0, so process substitution and a streamed shell work too.
bash -c 'printf "0\n" | sh <(cat "$1")' -- "$work/standalone.sh" > "$work/substitution.out"
grep -q 'Установка / обновление / удаление' "$work/substitution.out"
cat "$work/standalone.sh" | sh > "$work/stream.out"
grep -q 'До встречи' "$work/stream.out"
printf 'i\n\n0\n' | JZM_CONFIG=$work/manager.json DESTDIR=$work/bundle-image sh "$work/standalone.sh" > "$work/installed.out"
equal_file "$work/standalone.sh" "$work/bundle-image/usr/bin/jzm"
[ -x "$work/bundle-image/usr/bin/jzm" ]
printf 'i\n\n0\n' | JZM_CONFIG=$work/manager.json DESTDIR=$work/bundle-image sh "$work/standalone.sh" > "$work/reinstalled.out"
equal_file "$work/standalone.sh" "$work/bundle-image/usr/bin/jzm"
equal_file "$work/standalone.sh" "$work/bundle-image/usr/bin/jzm.previous"
[ -x "$work/bundle-image/usr/bin/jzm" ]
[ -x "$work/bundle-image/usr/bin/jzm.previous" ]
printf '2\n3\n\n0\n0\n' | JZM_CONFIG=$work/manager.json sh "$work/bundle-image/usr/bin/jzm" > "$work/installed-actions.out"
cli status | grep -q running
# Updates use the configured repository only and install atomically with a previous copy.
mkdir -p "$ZM_TEST_ROOT/usr/bin"
cp "$work/standalone.sh" "$ZM_TEST_ROOT/usr/bin/jzm"
sed 's/0\.1\.0/0.2.0/g' "$work/standalone.sh" > "$ZM_TEST_ROOT/manager-release"
ucode -S -D "source=$work/manager.json" -D "target=$work/update-config.json" -e '
    import * as fs from "fs";
    let c = json(fs.readfile(source));
    c.updater.repo = "jzm-fixture/manager";
    fs.writefile(target, sprintf("%J\n", c));
'
JZM_UPDATE_CONFIG=$work/update-config.json ucode -S -L "$ZM_HOME/src/lib" tests/update.uc
# Schedule changes must preserve every unrelated crontab line, including other Zapret jobs.
mkdir -p "$ZM_TEST_ROOT/etc/crontabs"
printf '7 1 * * * /root/other-zapret-job\n' > "$ZM_TEST_ROOT/etc/crontabs/root"
cp "$ZM_TEST_ROOT/etc/crontabs/root" "$work/cron.before"
cli schedule 3 "$work/urls.txt" "$work/catalog.txt"
grep -q '^0 3 .*# zapret-manager:zapret$' "$ZM_TEST_ROOT/etc/crontabs/root"
grep -q '^7 1 ' "$ZM_TEST_ROOT/etc/crontabs/root"
cli schedule off
equal_file "$ZM_TEST_ROOT/etc/crontabs/root" "$work/cron.before"
touch "$ZM_TEST_ROOT/fail-cron"
bad cli schedule 3 "$work/urls.txt" "$work/catalog.txt"
equal_file "$ZM_TEST_ROOT/etc/crontabs/root" "$work/cron.before"
# Recover a stale, complete snapshot without guessing or deleting unrelated paths.
lock=$ZM_TEST_ROOT/tmp/zapret-manager.zapret.lock
cp "$conf" "$work/recovery.before"
mkdir "$lock"
printf '2147483647\n' > "$lock/pid"
cp "$conf" "$lock/0"
cp "$hosts" "$lock/1"
cp "$ZM_TEST_ROOT/opt/zapret/ipset/zapret-hosts-user-exclude.txt" "$lock/2"
cp "$ZM_TEST_ROOT/opt/zapret/ipset/zapret-hosts-google.txt" "$lock/3"
touch "$lock/ready" "$lock/running"
printf 'corrupted\n' > "$conf"
printf 'corrupted\n' > "$hosts"
cli recover
equal_file "$conf" "$work/recovery.before"
equal_file "$hosts" "$work/hosts.before"
cli status | grep -q running
# Signal the supervisor while a helper is still running; rollback waits for that helper.
cp "$conf" "$work/signal.before"
cp "$statefile" "$work/signal-state.before"
touch "$ZM_TEST_ROOT/pause-probe"
cli benchmark "$work/urls.txt" "$work/catalog.txt" > "$work/signal.log" 2>&1 &
job=$!
attempt=0
while [ ! -f "$ZM_TEST_ROOT/probe-entered" ] && [ "$attempt" -lt 100 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
done
[ -f "$ZM_TEST_ROOT/probe-entered" ]
kill -TERM "$(cat "$lock/pid")"
if wait "$job"; then printf '%s\n' 'interrupted benchmark succeeded unexpectedly' >&2; exit 1; fi
equal_file "$conf" "$work/signal.before"
equal_file "$statefile" "$work/signal-state.before"
cli status | grep -q running
[ ! -d "$lock" ]
DESTDIR=$work/image sh tools/install.sh > /dev/null
[ -f "$work/image/usr/bin/jzm" ]
printf 'keep\n' > "$work/image/etc/zapret-manager/manager-config.json"
DESTDIR=$work/image sh tools/install.sh > /dev/null
[ "$(cat "$work/image/etc/zapret-manager/manager-config.json")" = keep ]
DESTDIR=$work/image sh tools/install.sh uninstall
[ ! -d "$work/image/etc/zapret-manager" ]
[ ! -f "$work/image/usr/bin/jzm" ]
printf '%s\n' 'integration: menu, UCI, rollback, sources, networking, readable bundle and installation OK'
sh tests/packages.sh

sh tests/safety.sh

sh tests/uninstall.sh
