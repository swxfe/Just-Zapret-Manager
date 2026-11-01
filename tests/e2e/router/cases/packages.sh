#!/bin/sh
set -eu
remove_packages() {
    jzm remove
    reject nfqws_pids
    for package in zapret luci-app-zapret; do
        if command -v apk >/dev/null 2>&1; then reject apk info -e "$package"
        else
            opkg status "$package" > "$root/package-status" || :
            reject grep -q 'Status: .* installed' "$root/package-status"
        fi
    done
    test -x /usr/bin/jzm
    jzm version
    jzm status | grep -q 'not installed'
    jzm uninstall all
    test ! -e /usr/bin/jzm
    test ! -e /usr/bin/jzm.previous
    test ! -e /etc/zapret-manager
    test ! -e /etc/config/zapret
    test ! -e /opt/zapret
    reject nfqws_pids
    nft list table inet fw4 >/dev/null
    cmp "$root/network.before" /etc/config/network
    cmp "$root/dhcp.before" /etc/config/dhcp
    cmp "$root/dropbear.before" /etc/config/dropbear
}
