#!/bin/sh
set -eu
devices() {
    jzm devices toggle 192.168.1.200
    jzm devices list | grep -q 'Исключён 192.168.1.200'
    sh -n /opt/zapret/init.d/openwrt/custom.d/20-jzm-exclude.sh
    nft list table inet zapret | grep -q '192.168.1.200'
    nft -a list chain inet zapret postrouting_hook > "$root/device-rules.before"
    jzm devices add 192.168.1.200
    jzm devices add 192.168.1.200
    (
        # shellcheck source=/dev/null
        . /opt/zapret/init.d/openwrt/custom.d/20-jzm-exclude.sh
        zapret_custom_firewall_nft
        zapret_custom_firewall_nft
    )
    nft -a list chain inet zapret postrouting_hook > "$root/device-rules.after"
    cmp "$root/device-rules.before" "$root/device-rules.after"
    jzm devices clear
    jzm devices remove 192.168.1.200
    jzm devices remove 192.168.1.200
    health
}
uninstall_manager() {
    jzm devices add 192.168.1.200
    jzm network quic on
    jzm backup save /etc/zapret-manager/backups/e2e-uninstall.json
    cp "$conf" "$root/uninstall-config.before"
    jzm uninstall manager
    test ! -e /usr/bin/jzm
    test ! -e /usr/bin/jzm.previous
    test ! -e /etc/zapret-manager
    test ! -e /opt/zapret/init.d/openwrt/custom.d/20-jzm-exclude.sh
    cmp "$root/uninstall-config.before" "$conf"
    reject uci -q get firewall.jzm_quic
    health
    JZM_MODE='command' sh /tmp/just-zapret-manager.sh manager-install
    test -x /usr/bin/jzm
}
