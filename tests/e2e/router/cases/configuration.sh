#!/bin/sh
set -eu
public_contract() {
    printf '0\n' | /usr/bin/jzm > "$root/menu"
    grep -q 'JZM · just-zapret-manager ' "$root/menu"
    grep -q 'base_general' "$root/menu"
    reject /usr/bin/jzm status
    jzm version
    jzm doctor
}
packages_luci() {
    for package in zapret luci-app-zapret; do
        if command -v apk >/dev/null 2>&1; then apk info -e "$package"
        else opkg status "$package" | grep -q 'Status: .* installed'; fi
    done
    ucode -S -e '
        import * as fs from "fs";
        import { sha256 } from "digest";
        let manifest=json(fs.readfile("/etc/zapret-manager/assets/manifest.json"));
        for (let fake in manifest.fakes) {
            assert(fake.source == "flowseal" && fake.path == "/opt/zapret/fakes/" + fake.name, "isolated Flowseal path");
            let entry=filter(manifest.files, (entry) => entry.target == "fake" && entry.name == fake.name)[0];
            let payload=fs.readfile(fake.path);
            assert(payload != null && sha256(payload) == entry.sha256, "package installation must preserve Flowseal bytes: " + fake.name);
        }
    '
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
    jzm source apply flowseal base_general
    jzm backup restore "$root/baseline.json"
    unchanged
    nfqws_pids > "$root/noop-pids.after"
    cmp "$root/noop-pids.before" "$root/noop-pids.after"
}
preset_label() {
    jzm config get NFQWS_OPT > "$root/opts"
    [ "$(grep -c '^#base_general$' "$root/opts")" -eq 1 ]
    [ "$(grep -c '^#' "$root/opts")" -eq 1 ]
    [ "$(jzm source show flowseal base_general)" = "$(jzm config get NFQWS_OPT)" ]
    health
}
modified_label() {
    jzm source show flowseal base_general > "$root/original.opts"
    sed 's/^--filter-tcp=80,443$/--filter-tcp=80,444/' "$root/original.opts" > "$root/modified.opts"
    reject cmp -s "$root/original.opts" "$root/modified.opts"
    uci set "zapret.@main[0].NFQWS_OPT=$(cat "$root/modified.opts")"
    uci commit zapret
    printf '0\n' | /usr/bin/jzm > "$root/menu"
    grep -q 'base_general (изменена пользователем)' "$root/menu"
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
    reject jzm source apply flowseal missing-e2e-preset
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
