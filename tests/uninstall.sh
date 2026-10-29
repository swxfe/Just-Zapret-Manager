#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
ZM_HOME=$(pwd -P)
JZM_REAL_UCODE=$(command -v ucode)
work=$(mktemp -d /tmp/jzm-uninstall-test.XXXXXX)
trap 'rm -rf -- "$work"' 0
ZM_TEST_ROOT=$work/router
export ZM_HOME ZM_TEST_ROOT JZM_REAL_UCODE
unset ZM_TRANSACTION JZM_BACKEND JZM_BOOTSTRAP
mkdir -p "$work/bin" "$ZM_TEST_ROOT/etc/config" "$ZM_TEST_ROOT/etc/init.d" \
    "$ZM_TEST_ROOT/etc/crontabs" "$ZM_TEST_ROOT/etc/zapret-manager/backups" \
    "$ZM_TEST_ROOT/opt/zapret/init.d/openwrt/custom.d" "$ZM_TEST_ROOT/opt/zapret/files/fake" \
    "$ZM_TEST_ROOT/usr/bin" "$ZM_TEST_ROOT/tmp"
printf '#!/bin/sh\nprintf "0\\n"\n' > "$work/bin/id"
cat > "$work/bin/ucode" <<'SHIM'
#!/bin/sh
set -eu
if [ -n "${ZM_TRANSACTION:-}" ] && [ -n "${JZM_UNINSTALL_FAULT:-}" ]; then
    sh "$ZM_HOME/src/shell/backend.sh" uninstall-cleanup "$ZM_TEST_ROOT" zapret "${JZM_UNINSTALL_KIND:-manager}"
    if [ "$JZM_UNINSTALL_FAULT" = signal ]; then
        touch "$ZM_TEST_ROOT/cleanup-complete"
        sleep 2
    fi
    exit 73
fi
exec "$JZM_REAL_UCODE" "$@"
SHIM
chmod +x "$work/bin/"*
PATH=$work/bin:$PATH
export PATH
for helper in init cron firewall; do
    if [ "$helper" = init ]; then target=zapret; else target=$helper; fi
    cp "tests/mock-$helper.sh" "$ZM_TEST_ROOT/etc/init.d/$target"
    chmod +x "$ZM_TEST_ROOT/etc/init.d/$target"
done
printf "config main 'main'\n\toption NFQWS_OPT '--filter-tcp=443'\n" > "$ZM_TEST_ROOT/etc/config/zapret"
printf "config defaults\n\toption flow_offloading '1'\n\toption flow_offloading_hw '1'\n" > "$ZM_TEST_ROOT/etc/config/firewall"
printf 'fixture executable\n' > "$ZM_TEST_ROOT/usr/bin/jzm"
printf 'previous executable\n' > "$ZM_TEST_ROOT/usr/bin/jzm.previous"
printf 'fake payload\n' > "$ZM_TEST_ROOT/opt/zapret/files/fake/game.bin"
printf '#!/bin/sh\nset -eu\n' > "$ZM_TEST_ROOT/opt/zapret/init.d/openwrt/custom.d/20-jzm-exclude.sh"
printf 'backup\n' > "$ZM_TEST_ROOT/etc/zapret-manager/backups/user.json"
printf '192.168.1.5\n' > "$ZM_TEST_ROOT/etc/zapret-manager/devices.txt"
touch "$ZM_TEST_ROOT/state" "$ZM_TEST_ROOT/enabled"
"$JZM_REAL_UCODE" -S -D "root=$ZM_TEST_ROOT" -D "destination=$work/config.json" -e '
    import * as fs from "fs";
    let c=json(fs.readfile("data/manager.json")); c.root=root; c.updater.repo=""; c.settle_seconds=0;
    fs.writefile(destination,sprintf("%J\n",c));
'
cli() { JZM_MODE='command' "$JZM_REAL_UCODE" -S -L "$ZM_HOME/src/lib" -- src/main.uc --config "$work/config.json" "$@"; }
bad() { if "$@" > "$work/error" 2>&1; then printf 'expected failure: %s\n' "$*" >&2; exit 1; fi; }
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
