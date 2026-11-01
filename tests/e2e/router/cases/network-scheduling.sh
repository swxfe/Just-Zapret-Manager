#!/bin/sh
set -eu
networking() {
    uci export firewall > "$root/firewall-before"
    jzm network offload disable
    [ "$(uci get 'firewall.@defaults[0].flow_offloading')" = 0 ]
    jzm network offload restore
    uci export firewall > "$root/firewall-after"
    cmp "$root/firewall-before" "$root/firewall-after"
    jzm network quic on
    [ "$(uci get firewall.jzm_quic.name)" = JZM_Block_QUIC ]
    nft list ruleset | grep -q JZM_Block_QUIC
    jzm network quic off
    reject uci -q get firewall.jzm_quic
    health
}
schedule() {
    printf '%s\n' '7 1 * * * /bin/true # unrelated-e2e' >> /etc/crontabs/root
    cp /etc/crontabs/root "$root/cron-before"
    jzm source export manager e2e-catalog.txt
    printf '%s\n' 'http://127.0.0.1/' > "$root/targets.txt"
    hour=$((($(date +%H | sed 's/^0//') + 12) % 24))
    jzm schedule "$hour" "$root/targets.txt" /etc/zapret-manager/e2e-catalog.txt
    grep -q 'JZM_MODE=command.*# zapret-manager:zapret$' /etc/crontabs/root
    grep -q unrelated-e2e /etc/crontabs/root
    jzm schedule off
    cmp "$root/cron-before" /etc/crontabs/root
}
