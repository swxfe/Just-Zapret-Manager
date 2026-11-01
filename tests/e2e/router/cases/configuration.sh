#!/bin/sh
set -eu
public_contract() {
    printf '0\n' | /usr/bin/jzm > "$root/menu"
    grep -q 'JZM · just-zapret-manager ' "$root/menu"
    grep -q 'v7' "$root/menu"
    reject /usr/bin/jzm status
    jzm version
    jzm doctor
}
packages_luci() {
    for package in zapret luci-app-zapret; do
        if command -v apk >/dev/null 2>&1; then apk info -e "$package"
        else opkg status "$package" | grep -q 'Status: .* installed'; fi
    done
    test -s /usr/share/luci/menu.d/luci-app-zapret.json
    test -s /www/luci-static/resources/view/zapret/settings.js
    curl --fail --max-time 10 http://127.0.0.1/luci-static/resources/view/zapret/settings.js > "$root/luci.js"
    test -s "$root/luci.js"
}
live_status() { jzm status; health; }
noop_preserves_process() {
    cp "$conf" "$root/before"
    nfqws_pids > "$root/noop-pids.before"
    ports=$(jzm config get NFQWS_PORTS_TCP)
    jzm config set NFQWS_PORTS_TCP "$ports"
    jzm source apply manager v7
    jzm backup restore "$root/baseline.json"
    unchanged
    nfqws_pids > "$root/noop-pids.after"
    cmp "$root/noop-pids.before" "$root/noop-pids.after"
}
preset_label() {
    jzm config get NFQWS_OPT > "$root/opts"
    [ "$(grep -c '^#v7$' "$root/opts")" -eq 1 ]
    [ "$(grep -c '^#' "$root/opts")" -eq 1 ]
    [ "$(jzm source show manager v7)" = "$(jzm config get NFQWS_OPT)" ]
    health
}
modified_label() {
    jzm source show manager v7 > "$root/original.opts"
    sed 's/^--filter-tcp=443$/--filter-tcp=444/' "$root/original.opts" > "$root/modified.opts"
    reject cmp -s "$root/original.opts" "$root/modified.opts"
    uci set "zapret.@main[0].NFQWS_OPT=$(cat "$root/modified.opts")"
    uci commit zapret
    printf '0\n' | /usr/bin/jzm > "$root/menu"
    grep -q 'v7 (изменена пользователем)' "$root/menu"
    health
}
invalid_ports() {
    nfqws_pids > "$root/reject-pids.before"
    cp "$conf" "$root/before"
    reject jzm config set NFQWS_PORTS_TCP 999999
    unchanged
    reject jzm config set NFQWS_PORTS_UDP 500-10
    nfqws_pids > "$root/reject-pids.after"
    cmp "$root/reject-pids.before" "$root/reject-pids.after"
    unchanged
}
invalid_strategy() {
    cp "$conf" "$root/before"
    reject jzm source apply manager missing-e2e-preset
    # This substitution must stay literal so the strategy validator can reject it.
    # shellcheck disable=SC2016
    printf '%s\n' '--filter-tcp=443' '--x=$(touch /tmp/jzm-e2e/injected)' > "$root/bad.txt"
    reject jzm strategy import "$root/bad.txt"
    [ ! -e "$root/injected" ]
    unchanged
}
service_cycle() {
    jzm service stop
    reject nfqws_pids
    jzm status | grep -q stopped
    jzm service start
    health
    jzm service restart
    health
}
autostart() {
    jzm service disable
    reject /etc/init.d/zapret enabled
    jzm service enable
    /etc/init.d/zapret enabled
}
settings() {
    jzm config set DISABLE_IPV6 1
    [ "$(jzm config get DISABLE_IPV6)" = 1 ]
    jzm config set NFQWS_PORTS_TCP 80,443,2000-3000
    [ "$(jzm config get NFQWS_PORTS_TCP)" = 80,443,2000-3000 ]
    health
}
