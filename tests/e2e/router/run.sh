#!/bin/sh
set -eu
cases='public_contract packages_luci live_status noop_preserves_process preset_label modified_label invalid_ports invalid_strategy service_cycle autostart settings hostlists backup_roundtrip invalid_backup url_probe benchmark_preserves_state compound_groups flowseal devices networking schedule noop_update manager_reinstall busy_lock failed_download github_rate_limit blockcheck_restore rollback_after_write interrupted_transaction uninstall_manager remove_packages'
case "${1:-}" in
--case)
    [ "$#" -eq 2 ]
    case " $cases " in *" $2 "*) "$2";; *) exit 2;; esac
    exit 0;;
--reset) set -x; reset; exit 0;;
'') ;;
*) exit 2;;
esac
mkdir -p "$root/report"
cp /etc/config/firewall "$root/firewall"
if [ -f /etc/crontabs/root ]; then cp -p /etc/crontabs/root "$root/cron"; else touch "$root/cron.absent"; fi
jzm backup save "$root/baseline.json"
# Normalize empty hooks once, then compare the complete restore set between cases.
jzm backup restore "$root/baseline.json" > "$root/report/baseline-setup.log" 2>&1
health
mkdir -p "$root/baseline-files"
baseline_files save
cp /etc/config/network "$root/network.before"
cp /etc/config/dhcp "$root/dhcp.before"
cp /etc/config/dropbear "$root/dropbear.before"
: > "$root/report/results.tsv"
failed=0
number=0
blocked=0
printf 'TAP version 13\n'
for name in $cases; do
    number=$((number + 1))
    if [ "$blocked" = 1 ]; then
        printf 'ok %s - %s # SKIP baseline recovery failed\n' "$number" "$name"
        printf 'skip\t%s\t0\n' "$name" >> "$root/report/results.tsv"
        continue
    fi
    start=$(date +%s)
    # A new shell keeps errexit effective; functions invoked inside an if lose it in POSIX sh.
    if sh "$0" --case "$name" > "$root/report/$name.log" 2>&1; then result=pass; verdict=ok
    else result=fail; verdict='not ok'; failed=1; fi
    printf '%s %s - %s\n' "$verdict" "$number" "$name"
    printf '%s\t%s\t%s\n' "$result" "$name" "$(($(date +%s) - start))" >> "$root/report/results.tsv"
    if [ "$result" = fail ]; then sed 's/^/# /' "$root/report/$name.log"; fi
    # Package removal is deliberately last; this flash copy is discarded by the host.
    [ "$name" != remove_packages ] || continue
    reset_start=$(date +%s)
    if ! sh "$0" --reset > "$root/report/$name.reset.log" 2>&1; then
        printf '# baseline recovery failed; remaining cases will be skipped\n'
        printf 'fail\t%s_reset\t0\n' "$name" >> "$root/report/results.tsv"
        failed=1; blocked=1
    fi
    printf '%s\t%s\n' "$name" "$(($(date +%s) - reset_start))" >> "$root/report/resets.tsv"
done
printf '1..%s\n' "$number"
touch "$root/report/complete"
exit "$failed"
