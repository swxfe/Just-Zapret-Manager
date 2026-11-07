#!/bin/sh
set -eu
hostlists() {
    jzm hosts user add EXAMPLE.COM example.com sub.example.com
    jzm hosts user show > "$root/hosts"
    [ "$(grep -c '^example.com$' "$root/hosts")" -eq 1 ]
    jzm hosts user remove example.com
    jzm hosts user show > "$root/hosts"
    reject grep -q '^example.com$' "$root/hosts"
    reject jzm hosts user add 'bad.example;touch /tmp/jzm-e2e/injected'
    [ ! -e "$root/injected" ]
    health
}
backup_roundtrip() {
    cp "$conf" "$root/before"
    jzm backup save "$root/roundtrip.json"
    jzm config set DISABLE_IPV6 1
    jzm hosts user add backup.example
    jzm backup restore "$root/roundtrip.json"
    unchanged
    jzm config get NFQWS_OPT | grep -q '^#base_general$'
    reject jzm backup save "$root/roundtrip.json"
}
invalid_backup() {
    cp "$conf" "$root/before"
    printf '%s\n' '{"format":1,"profile":"wrong"}' > "$root/bad.json"
    reject jzm backup restore "$root/bad.json"
    unchanged
}
