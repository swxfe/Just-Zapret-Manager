#!/bin/sh
set -eu
umask 077
project=$(CDPATH='' cd -P "$(dirname "$0")/../.." && pwd)

host_python() { python3 -B "$project/tests/e2e/host/cli.py" "$project" "$@"; }
bootstrap_script() { cat "$project/tests/setup/router-bootstrap.sh"; }
router_script() {
    cat "$project/tests/e2e/router/common.sh" \
        "$project/tests/e2e/router/cases/configuration.sh" \
        "$project/tests/e2e/router/cases/hostlists-backups.sh" \
        "$project/tests/e2e/router/cases/strategies-probes.sh" \
        "$project/tests/e2e/router/cases/devices-uninstall.sh" \
        "$project/tests/e2e/router/cases/network-scheduling.sh" \
        "$project/tests/e2e/router/cases/manager-update.sh" \
        "$project/tests/e2e/router/cases/rollback.sh" \
        "$project/tests/e2e/router/cases/packages.sh" \
        "$project/tests/e2e/router/run.sh"
}
# shellcheck source=tests/setup/emulator.sh
. "$project/tests/setup/emulator.sh"

case "${1:-run}" in
    setup) [ "$#" -eq 1 ] || exit 2; setup_emulator; exit;;
    selftest) [ "$#" -eq 1 ] || exit 2; host_python selftest; exit;;
    payload)
        [ "$#" -eq 2 ] || exit 2
        case "$2" in bootstrap) bootstrap_script;; router) router_script;; *) exit 2;; esac
        exit;;
    run) [ "$#" -eq 0 ] || { [ "$#" -eq 1 ] || exit 2; shift; };;
    *) printf '%s\n' 'usage: tests/e2e/run.sh [run|setup|selftest]' >&2; exit 2;;
esac

emulator=$project/.emulator
version=${E2E_OPENWRT_VERSION:-25.12.5}
boot_timeout=${E2E_BOOT_TIMEOUT:-60}
command_timeout=${E2E_COMMAND_TIMEOUT:-1800}
port=${E2E_SSH_PORT:-8022}
run=$(date -u +%Y%m%dT%H%M%SZ)-$$
reports=$project/.test-tmp/e2e
report=$reports/$run
mkdir -p "$report"
printf 'E2E logs: %s\n' "$report"
: > "$report/host.tsv"
EMU_PID=''
STAGE_PID=''
runtime=''
owned_lock=0
ssh_ready=0
guest_started=0
active=''
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$report/host.tsv"; }
remote_limit() {
    limit=$1; shift
    timeout --kill-after=5 "$limit" ssh -F /dev/null -T \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null \
        -o BatchMode=yes -o IdentityAgent=none -o ConnectTimeout=2 \
        -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -p "$port" root@127.0.0.1 "$@"
}
remote() { remote_limit "$command_timeout" "$@"; }
copy_to() {
    # Dropbear images may not include SFTP; legacy SCP works before package bootstrap.
    timeout --kill-after=5 60 scp -F /dev/null -O -q \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null \
        -o BatchMode=yes -o IdentityAgent=none -o ConnectTimeout=2 -P "$port" "$1" "root@127.0.0.1:$2"
}
collect() {
    timeout --kill-after=2 20 scp -F /dev/null -O -q -r \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null \
        -o BatchMode=yes -o IdentityAgent=none -o ConnectTimeout=2 -P "$port" \
        root@127.0.0.1:/tmp/jzm-e2e/report "$report/guest"
}
stop_emulator() {
    [ -n "$EMU_PID" ] || return 0
    # The upstream launcher waits for QEMU without forwarding signals. setsid gives both our own PGID.
    kill -TERM "$EMU_PID" 2>/dev/null || :
    kill -TERM "-$EMU_PID" 2>/dev/null || :
    attempt=0
    while kill -0 "-$EMU_PID" 2>/dev/null && [ "$attempt" -lt 5 ]; do
        sleep 1
        attempt=$((attempt + 1))
    done
    kill -KILL "-$EMU_PID" 2>/dev/null || :
    kill -KILL "$EMU_PID" 2>/dev/null || :
    wait "$EMU_PID" 2>/dev/null || :
    EMU_PID=''
}
finish() {
    rc=$?
    trap - 0 INT TERM HUP
    set +e
    if [ -n "$active" ]; then record fail "$active" 0; fi
    if [ -n "$STAGE_PID" ]; then
        kill -TERM "$STAGE_PID" 2>/dev/null || :
        kill -TERM "-$STAGE_PID" 2>/dev/null || :
    fi
    if [ "$guest_started" = 1 ]; then
        if ! collect > "$report/collect.log" 2>&1; then record fail collect_guest_reports 0; rc=1; fi
        if [ ! -f "$report/guest/complete" ]; then record fail guest_suite_incomplete 0; rc=1; fi
    fi
    if [ "$ssh_ready" = 1 ]; then
        # Diagnostics must not hold up process cleanup when the guest is unresponsive.
        remote_limit 15 'uname -a; cat /etc/openwrt_release; ubus call system board; JZM_MODE=command /usr/bin/jzm status; uci show zapret; pgrep -a nfqws; nft list ruleset; logread | tail -n 150; df -h' \
            > "$report/diagnostics.log" 2>&1 || :
    fi
    stop_emulator
    if [ -n "$runtime" ]; then
        case "$runtime" in /tmp/jzm-e2e.*) rm -rf -- "$runtime";; esac
    fi
    if [ "$owned_lock" = 1 ]; then
        rm -f "$emulator/.e2e.lock/pid"
        if ! rmdir "$emulator/.e2e.lock"; then record fail cleanup_lock 0; rc=1; fi
    fi
    if ! host_python report "$report" "$rc"; then
        record fail render_report 0
        rc=1
        # A missing Python installation still leaves a report explaining the failed preflight.
        awk -F '\t' 'BEGIN {print "TAP version 13"} {n++; print ($1=="fail"?"not ok":"ok"),n,"-",$2} END {print "1.."n}' \
            "$report/host.tsv" > "$report/report.tap"
        printf '%s\n' '{"success":false,"error":"report generator unavailable; see host.tsv and logs"}' > "$report/report.json"
        printf '%s\n' 'E2E FAIL: report generator unavailable' | tee "$report/summary.txt"
    fi
    printf '%s\n' "$report" > "$reports/latest.txt"
    printf 'Отчёты: %s\n' "$report"
    exit "$rc"
}
trap finish 0
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
stage() {
    name=$1; shift
    active=$name
    start=$(date +%s)
    printf 'E2E: %s ...\n' "$name"
    # wait is interrupted immediately by signals; a synchronous SSH could defer the trap for minutes.
    # Background lists otherwise receive /dev/null, losing the bootstrap script supplied on stdin.
    exec 3<&0
    "$@" > "$report/$name.log" 2>&1 <&3 &
    STAGE_PID=$!
    exec 3<&-
    if wait "$STAGE_PID"; then
        record pass "$name" "$(($(date +%s) - start))"
        active=''
        STAGE_PID=''
    else
        code=$?
        record fail "$name" "$(($(date +%s) - start))"
        active=''
        STAGE_PID=''
        cat "$report/$name.log" >&2
        return "$code"
    fi
}
preflight() {
    [ "$#" -eq 0 ] || return 2
    if [ "$(uname -s):$(uname -m)" != Linux:x86_64 ]; then
        printf '%s\n' 'E2E: нужен Linux x86_64 или WSL2. Git Bash не исполняет Linux QEMU.' >&2
        return 1
    fi
    for tool in python3 bash ssh scp setsid timeout; do
        command -v "$tool" >/dev/null 2>&1 || { printf 'E2E: нужна команда %s\n' "$tool" >&2; return 1; }
    done
    for value in "$boot_timeout" "$command_timeout" "$port"; do
        case "$value" in ''|*[!0-9]*) printf '%s\n' 'E2E: таймауты и порт должны быть целыми числами' >&2; return 1;; esac
        [ "$value" -gt 0 ] && [ "$value" -le 65535 ] || return 1
    done
    case "$version" in ''|*[!0-9.]*|.*|*..*|*.) return 1;; esac
    test -s "$project/dist/just-zapret-manager.sh" || return 1
    python3 - "$port" <<'PY'
import socket, sys
with socket.socket() as listener:
    listener.bind(("127.0.0.1", int(sys.argv[1])))
PY
}
wait_ssh() {
    deadline=$(($(date +%s) + boot_timeout))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        kill -0 "$EMU_PID" 2>/dev/null || { cat "$report/emulator.log" >&2; return 1; }
        remaining=$((deadline - $(date +%s)))
        [ "$remaining" -gt 0 ] || break
        limit=2
        [ "$remaining" -ge 2 ] || limit=$remaining
        if remote_limit "$limit" 'echo ready' > "$report/ssh-last.log" 2>&1; then
            grep -q '^ready$' "$report/ssh-last.log" && return 0
        fi
        sleep 1
    done
    printf 'SSH не готов за %s секунд. UART: %s/console/\n' "$boot_timeout" "$report" >&2
    cat "$report/ssh-last.log" >&2 || :
    return 1
}
require_emulator() {
    for file in "$emulator/emulator.sh" "$emulator/qemu/qemu-system-aarch64" "$emulator/.jzm-release.json" \
        "$emulator/presets/cudy-wr3000p-v1.ini" "$emulator/images/$version/nand-wr3000p/.jzm-ready"; do
        [ -s "$file" ] || { printf '%s\n' 'Эмулятор не подготовлен: выполните just emulator-setup' >&2; return 1; }
    done
}
stage preflight preflight "$@"
stage emulator_ready require_emulator
active=acquire_lock
mkdir "$emulator/.e2e.lock" 2>/dev/null || { printf 'Другой E2E уже запущен: %s/.e2e.lock\n' "$emulator" >&2; exit 1; }
owned_lock=1
printf '%s\n' "$$" > "$emulator/.e2e.lock/pid"
active=''
active=copy_pristine_flash
runtime=$(mktemp -d /tmp/jzm-e2e.XXXXXX)
mkdir "$runtime/flash"
cp -Rp "$emulator/images/$version/nand-wr3000p/." "$runtime/flash/"
bootstrap_script > "$runtime/bootstrap.sh"
router_script > "$runtime/router.sh"
record pass copy_pristine_flash 0
active=launch_emulator
# Positional parameters are expanded by the session's shell, not by this launcher.
# shellcheck disable=SC2016
QEMU_BIN=$emulator/qemu/qemu-system-aarch64 setsid sh -c 'cd "$1" && exec ./emulator.sh -P cudy-wr3000p-v1 -w user -l user -u none -o "lan-forwards=$6:22" -n "$2" -S "$3" -m "$4" -L "$5"' \
    jzm-emulator "$emulator" "$runtime/flash" "$runtime/console.sock" "$runtime/monitor.sock" "$report/console" "$port" \
    > "$report/emulator.log" 2>&1 </dev/null &
EMU_PID=$!
record pass launch_emulator 0
active=''
stage ssh_ready wait_ssh
ssh_ready=1
# Fresh flash has no persisted clock; HTTPS certificate verification needs host UTC.
stage guest_bootstrap remote "date -u -s '@$(date +%s)' && JZM_E2E_GUEST=1 sh -s" < "$runtime/bootstrap.sh"
stage upload_manager copy_to "$project/dist/just-zapret-manager.sh" /tmp/just-zapret-manager.sh
# Installation is an internal command too; public positional arguments remain forbidden.
stage upload_assets copy_to "$project/dist/jzm-assets.tar.gz" /tmp/jzm-assets.tar.gz
stage install_manager remote 'JZM_MODE=command sh /tmp/just-zapret-manager.sh manager-install /tmp/jzm-assets.tar.gz && test -x /usr/bin/jzm'
stage install_zapret_luci remote 'JZM_MODE=command /usr/bin/jzm install-upstream'
stage local_flowseal_catalog remote 'JZM_MODE=command /usr/bin/jzm source list flowseal'
stage apply_base_general remote 'JZM_MODE=command /usr/bin/jzm source apply flowseal base_general'
stage upload_suite copy_to "$runtime/router.sh" /tmp/jzm-e2e-router.sh
guest_started=1
stage router_suite remote 'JZM_E2E_GUEST=1 sh /tmp/jzm-e2e-router.sh'
cat "$report/router_suite.log"
