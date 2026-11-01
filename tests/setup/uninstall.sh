#!/bin/sh
set -eu
ZM_HOME=$(pwd -P)
JZM_HTTP_PROVIDER=$ZM_HOME/tests/mocks/http-provider.uc
export JZM_HTTP_PROVIDER
JZM_REAL_UCODE=$(command -v ucode)
work=$(mktemp -d /tmp/jzm-uninstall-test.XXXXXX)
procd_pid=''
trap 'if [ -n "$procd_pid" ]; then kill "$procd_pid" 2>/dev/null || :; wait "$procd_pid" 2>/dev/null || :; fi; rm -rf -- "$work"' 0
ZM_TEST_ROOT=$work/router
export ZM_HOME ZM_TEST_ROOT JZM_REAL_UCODE
unset ZM_TRANSACTION JZM_BACKEND JZM_BOOTSTRAP
mkdir -p "$work/bin" "$ZM_TEST_ROOT/etc/config" "$ZM_TEST_ROOT/etc/init.d" \
    "$ZM_TEST_ROOT/etc/crontabs" "$ZM_TEST_ROOT/etc/zapret-manager/backups" \
    "$ZM_TEST_ROOT/opt/zapret/init.d/openwrt/custom.d" "$ZM_TEST_ROOT/opt/zapret/files/fake" \
    "$ZM_TEST_ROOT/usr/bin" "$ZM_TEST_ROOT/tmp"
cp tests/mocks/id.sh "$work/bin/id"
cp tests/mocks/uninstall/ucode.sh "$work/bin/ucode"
chmod +x "$work/bin/"*
PATH=$work/bin:$PATH
export PATH
sh tests/setup/procd.sh "$ZM_TEST_ROOT" &
procd_pid=$!
attempt=0
while [ ! -f "$ZM_TEST_ROOT/tmp/procd-ready" ]; do
    attempt=$((attempt + 1)); [ "$attempt" -le 100 ] || exit 1
    sleep 0.01
done
for helper in zapret-init cron firewall; do
    if [ "$helper" = zapret-init ]; then target=zapret; else target=$helper; fi
    cp "tests/mocks/$helper.sh" "$ZM_TEST_ROOT/etc/init.d/$target"
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
