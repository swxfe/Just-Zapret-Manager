#!/bin/sh
set -eu
ZM_HOME=$(pwd -P)
JZM_HTTP_PROVIDER=$ZM_HOME/tests/mocks/http-provider.uc
export ZM_HOME JZM_HTTP_PROVIDER
for tool in ucode uci sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'test: нужен %s\n' "$tool" >&2; exit 1; }
done
work=$(mktemp -d "${TMPDIR:-/tmp}/zm-integration-XXXXXX")
procd_pid=''
trap 'if [ -n "$procd_pid" ]; then kill "$procd_pid" 2>/dev/null || :; wait "$procd_pid" 2>/dev/null || :; fi; rm -rf -- "$work"' 0
ZM_TEST_ROOT=$work/router
export ZM_TEST_ROOT
mkdir -p "$ZM_TEST_ROOT/etc/config" "$ZM_TEST_ROOT/etc/init.d" "$ZM_TEST_ROOT/opt/zapret/ipset" "$ZM_TEST_ROOT/tmp" "$work/bin"
sh tests/setup/procd.sh "$ZM_TEST_ROOT" &
procd_pid=$!
attempt=0
while [ ! -f "$ZM_TEST_ROOT/tmp/procd-ready" ]; do
    attempt=$((attempt + 1)); [ "$attempt" -le 100 ] || exit 1
    sleep 0.01
done
cat > "$ZM_TEST_ROOT/etc/config/zapret" <<'EOF'
config main 'main'
    option NFQWS_OPT '--dpi-desync=fake'
    option DISABLE_IPV6 '1'
    option NFQWS_PORTS_TCP '80,443'
EOF
cc -shared -fPIC -Wall -Wextra -Werror tests/mocks/faults.c -ldl -o "$work/faults.so"
cp tests/mocks/zapret-init.sh "$ZM_TEST_ROOT/etc/init.d/zapret"
cp tests/mocks/cron.sh "$ZM_TEST_ROOT/etc/init.d/cron"
cp tests/mocks/firewall.sh "$ZM_TEST_ROOT/etc/init.d/firewall"
cp tests/mocks/curl.sh "$work/bin/curl"
# Only the temporary fixture sees this privilege shim; no host paths are passed to mutations.
cp tests/mocks/id.sh "$work/bin/id"
# Some OpenWrt images omit the stat applet. All writes and rollback must work without it.
cp tests/mocks/missing-stat.sh "$work/bin/stat"
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
