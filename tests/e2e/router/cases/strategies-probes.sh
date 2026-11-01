#!/bin/sh
set -eu
url_probe() {
    printf '%s\n' 'http://127.0.0.1/luci-static/resources/view/zapret/settings.js' > "$root/targets.txt"
    jzm test "$root/targets.txt" > "$root/probe.json"
    grep -q 'OK http://' "$root/probe.json"
    health
}
benchmark_preserves_state() {
    cp "$conf" "$root/before"
    jzm source show manager v7 > "$root/bench-catalog.txt"
    printf '%s\n' 'http://127.0.0.1/luci-static/resources/view/zapret/settings.js' > "$root/targets.txt"
    jzm service stop
    jzm benchmark "$root/targets.txt" "$root/bench-catalog.txt"
    cmp "$root/before" "$conf"
    reject nfqws_pids
    jzm service start
    jzm auto-best "$root/targets.txt" "$root/bench-catalog.txt"
    unchanged
}
compound_groups() {
    jzm source compose manager v7 Yv08 Dv1 Gv1
    jzm config get NFQWS_OPT > "$root/opts"
    for name in v7 Yv08 Dv1 Gv1; do [ "$(grep -c "^#$name\$" "$root/opts")" -eq 1 ]; done
    [ "$(grep -c '^--new$' "$root/opts")" -eq 4 ]
    health
    jzm source group manager base v3
    jzm config get NFQWS_OPT > "$root/opts"
    for name in v3 Yv08 Dv1 Gv1; do [ "$(grep -c "^#$name\$" "$root/opts")" -eq 1 ]; done
    reject grep -q '^#v7$' "$root/opts"
    health
}
flowseal() {
    jzm source refresh flowseal
    jzm source list flowseal > "$root/flowseal-names"
    name=$(sed -n '1p' "$root/flowseal-names")
    if grep -q '^general$' "$root/flowseal-names"; then name=general; fi
    alt9=$(grep -i '^general[_ (]*alt9[_ )]*$' "$root/flowseal-names" | head -n 1)
    if [ -n "$alt9" ]; then name=$alt9; fi
    [ -n "$name" ]
    jzm source apply flowseal "$name"
    jzm config get NFQWS_OPT > "$root/opts"
    [ "$(grep -c '^#' "$root/opts")" -eq 1 ]
    grep -q "^#$name\$" "$root/opts"
    [ "$(jzm source show flowseal "$name")" = "$(jzm config get NFQWS_OPT)" ]
    health
    jzm source group manager games Gv1
    jzm config get NFQWS_OPT > "$root/opts"
    grep -q "^#$name\$" "$root/opts"
    [ "$(grep -c '^#Gv1$' "$root/opts")" -eq 1 ]
    health
    jzm source remove manager games
    jzm config get NFQWS_OPT > "$root/opts"
    grep -q "^#$name\$" "$root/opts"
    reject grep -q '^#Gv1$' "$root/opts"
    health
}
