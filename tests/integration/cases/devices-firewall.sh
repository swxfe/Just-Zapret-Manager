#!/bin/sh
set -eu
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
cp tests/support/check-exclusion-hook.sh "$work/check-hook.sh"
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
