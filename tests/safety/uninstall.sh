#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
. tests/setup/uninstall.sh

cli network offload disable
cli network quic on
printf '7 1 * * * /bin/true # unrelated\n0 4 * * * jzm # zapret-manager:zapret\n' > "$ZM_TEST_ROOT/etc/crontabs/root"
cp -pR "$ZM_TEST_ROOT/etc/zapret-manager" "$work/state.before"
cp "$ZM_TEST_ROOT/etc/config/firewall" "$work/firewall.before"
cp "$ZM_TEST_ROOT/etc/config/zapret" "$work/zapret.before"
cp "$ZM_TEST_ROOT/etc/crontabs/root" "$work/cron.before"
assert_restored() {
    diff -r "$work/state.before" "$ZM_TEST_ROOT/etc/zapret-manager"
    cmp "$work/firewall.before" "$ZM_TEST_ROOT/etc/config/firewall"
    cmp "$work/zapret.before" "$ZM_TEST_ROOT/etc/config/zapret"
    cmp "$work/cron.before" "$ZM_TEST_ROOT/etc/crontabs/root"
    test -f "$ZM_TEST_ROOT/usr/bin/jzm"
    test -f "$ZM_TEST_ROOT/usr/bin/jzm.previous"
    test -f "$ZM_TEST_ROOT/opt/zapret/init.d/openwrt/custom.d/20-jzm-exclude.sh"
    test -f "$ZM_TEST_ROOT/opt/zapret/files/fake/game.bin"
    test -f "$ZM_TEST_ROOT/state"
    test -f "$ZM_TEST_ROOT/enabled"
    test ! -d "$ZM_TEST_ROOT/tmp/zapret-manager.zapret.lock"
}
touch "$ZM_TEST_ROOT/fail-firewall"
bad cli uninstall manager
assert_restored
JZM_UNINSTALL_FAULT=abort bad cli uninstall manager
assert_restored
JZM_UNINSTALL_KIND=all JZM_UNINSTALL_FAULT=abort bad cli uninstall manager
assert_restored
JZM_UNINSTALL_FAULT=signal cli uninstall manager > "$work/signal.log" 2>&1 &
job=$!
attempt=0
while [ ! -f "$ZM_TEST_ROOT/cleanup-complete" ] && [ "$attempt" -lt 100 ]; do sleep 0.1; attempt=$((attempt + 1)); done
test -f "$ZM_TEST_ROOT/cleanup-complete"
kill -TERM "$(cat "$ZM_TEST_ROOT/tmp/zapret-manager.zapret.lock/pid")"
if wait "$job"; then printf 'interrupted uninstall passed unexpectedly\n' >&2; exit 1; fi
assert_restored
cli uninstall manager
cmp "$work/zapret.before" "$ZM_TEST_ROOT/etc/config/zapret"
test -f "$ZM_TEST_ROOT/opt/zapret/files/fake/game.bin"
test -f "$ZM_TEST_ROOT/state"
test -f "$ZM_TEST_ROOT/enabled"
test ! -e "$ZM_TEST_ROOT/usr/bin/jzm"
test ! -e "$ZM_TEST_ROOT/usr/bin/jzm.previous"
test ! -e "$ZM_TEST_ROOT/etc/zapret-manager"
test ! -e "$ZM_TEST_ROOT/opt/zapret/init.d/openwrt/custom.d/20-jzm-exclude.sh"
test "$(uci -c "$ZM_TEST_ROOT/etc/config" -q get 'firewall.@defaults[0].flow_offloading')" = 1
test "$(uci -c "$ZM_TEST_ROOT/etc/config" -q get 'firewall.@defaults[0].flow_offloading_hw')" = 1
if uci -c "$ZM_TEST_ROOT/etc/config" -q get firewall.jzm_quic; then exit 1; fi
printf '7 1 * * * /bin/true # unrelated\n' > "$work/cron.expected"
cmp "$work/cron.expected" "$ZM_TEST_ROOT/etc/crontabs/root"
cli uninstall manager
printf '%s\n' 'uninstall: failure/signal rollback, backups, firewall, cron, idempotency and preserved Zapret OK'
