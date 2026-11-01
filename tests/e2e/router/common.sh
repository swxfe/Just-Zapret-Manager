#!/bin/sh
# Test functions are selected by the validated --case dispatcher below.
# shellcheck disable=SC2329
set -eu
umask 077
root=/tmp/jzm-e2e
conf=/etc/config/zapret
lock=/tmp/zapret-manager.zapret.lock
[ "${JZM_E2E_GUEST:-}" = 1 ] && [ -f "$root/guard" ] && [ -f /etc/openwrt_release ] || exit 2
jzm() { JZM_MODE='command' /usr/bin/jzm "$@"; }
reject() { if "$@"; then printf 'unexpected success: %s\n' "$*" >&2; return 1; fi; }
nfqws_pids() {
    # BusyBox -x matches argv[0] (the full path), unlike procps on the host.
    pgrep -f '^/opt/zapret/nfq/nfqws([[:space:]]|$)'
}
health() {
    attempts=0
    while [ "$attempts" -lt 20 ]; do
        if /etc/init.d/zapret running && nfqws_pids > "$root/pids"; then
            nft list table inet zapret > "$root/rules"
            grep -q 'chain ' "$root/rules"
            /etc/init.d/zapret enabled || { printf '%s\n' 'health: Zapret не включён в автозагрузку' >&2; return 1; }
            return 0
        fi
        sleep 1
        attempts=$((attempts + 1))
    done
    printf '%s\n' 'health: procd или процесс nfqws не готов за 20 секунд' >&2
    return 1
}
unchanged() { cmp "$root/before" "$conf"; health; [ ! -d "$lock" ]; }
baseline_files() {
    mode=$1
    index=0
    set -- "$conf" /opt/zapret/ipset/zapret-hosts-user.txt \
        /opt/zapret/ipset/zapret-hosts-user-exclude.txt /opt/zapret/ipset/zapret-hosts-google.txt \
        /etc/zapret-manager/state.json /etc/zapret-manager/devices.txt \
        /opt/zapret/init.d/openwrt/custom.d/20-jzm-exclude.sh
    for path do
        [ -f "$path" ] && [ ! -L "$path" ] || return 1
        if [ "$mode" = save ]; then cp -p "$path" "$root/baseline-files/$index" || return 1
        else cmp -s "$path" "$root/baseline-files/$index" || return 1; fi
        index=$((index + 1))
    done
    # Copy-on-write may change mtimes; compare permissions and ownership in addition to bytes.
    LC_ALL=C ls -ldn "$@" > "$root/baseline-metadata.raw" || return 1
    if [ "$mode" = save ]; then awk '{print $1, $3, $4}' "$root/baseline-metadata.raw" > "$root/baseline-files/metadata"
    else
        awk '{print $1, $3, $4}' "$root/baseline-metadata.raw" > "$root/baseline-current-metadata" || return 1
        cmp -s "$root/baseline-current-metadata" "$root/baseline-files/metadata"
    fi
}
baseline_running() {
    /etc/init.d/zapret running || return 1
    nfqws_pids > "$root/pids" || return 1
    nft list table inet zapret > "$root/rules" || return 1
    grep -q 'chain ' "$root/rules"
}
reset() {
    # A killed fault-injection worker must not affect the next independent case.
    if [ -f "$root/sync.original" ]; then cp -p "$root/sync.original" /opt/zapret/sync_config.sh; fi
    rm -f "$root/fail-sync" "$root/probe-entered"
    if [ -d "$lock" ]; then jzm recover; fi
    if ! cmp -s "$root/firewall" /etc/config/firewall; then
        cp -p "$root/firewall" /etc/config/firewall
        /etc/init.d/firewall restart
    fi
    if [ -f "$root/cron.absent" ]; then
        if [ -f /etc/crontabs/root ]; then rm /etc/crontabs/root; /etc/init.d/cron restart; fi
    elif ! cmp -s "$root/cron" /etc/crontabs/root; then
        cp -p "$root/cron" /etc/crontabs/root
        /etc/init.d/cron restart
    fi
    rm -f /etc/zapret-manager/offload.previous
    # Reapply the real backup only when managed files differ; keep every case's assertions intact.
    if ! baseline_files check; then jzm backup restore "$root/baseline.json"; fi
    if ! baseline_running; then jzm service restart; fi
    if ! /etc/init.d/zapret enabled; then jzm service enable; fi
    health
}
