#!/bin/sh
set -eu
noop_update() {
    cp "$conf" "$root/before"
    jzm update-upstream > "$root/update"
    grep -q 'Новых версий нет' "$root/update"
    unchanged
}
manager_reinstall() {
    cp "$conf" "$root/before"
    cp /etc/zapret-manager/manager-config.json "$root/manager-before"
    jzm manager-install
    test -x /usr/bin/jzm
    test -x /usr/bin/jzm.previous
    cmp /usr/bin/jzm /usr/bin/jzm.previous
    cmp "$root/manager-before" /etc/zapret-manager/manager-config.json
    unchanged
}
