#!/bin/sh
# shellcheck source=src/shell/common.sh
. "$(dirname "$0")/common.sh"

config_unchanged() {
    while [ "${1:-}" = --config ]; do
        [ "$#" -ge 2 ] || return 1
        shift 2
    done
    [ "$#" -eq 4 ] && [ "$1" = config ] && [ "$2" = set ] || return 1
    case "$3" in DISABLE_IPV6|DISABLE_CUSTOM|ENABLED|DEBUG|MODE_FILTER|NFQWS_PORTS_TCP|NFQWS_PORTS_UDP) ;;
        *) return 1;; esac
    # Only committed configuration is read, under the same exclusive lock as writes.
    current=$(uci -c "$confdir" -t "$lock/delta" -q get "$profile.$section.$3" && printf x) || return 1
    # Preserve trailing newlines in the value; remove the sentinel and UCI's one terminator only.
    current=${current%x}
    current=${current%?}
    [ "$current" = "$4" ]
}

snapshot() {
    for idx in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17; do
        managed_path "$idx"
        path=$managed_file
        if [ -f "$path" ]; then cp -p "$path" "$lock/$idx"; else : > "$lock/$idx.absent"; fi
    done
}
reset_config() {
    [ -n "${ZM_TRANSACTION:-}" ] && [ "$ZM_TRANSACTION" = "$lock" ] || fail 'нет активной транзакции'
    if [ -f "$lock/0" ]; then atomic_copy "$lock/0" "$config"; else rm -f "$config"; fi
}
reset_all() {
    ZM_ROLLBACK=1
    export ZM_ROLLBACK
    if [ -f "$lock/uninstall.ready" ]; then
        for tree in state zapret; do
            if [ "$tree" = state ]; then path=$root/etc/zapret-manager; else path=$base; fi
            if [ -d "$lock/uninstall-$tree" ]; then
                rm -rf -- "$path" || return 1
                mkdir -p "$(dirname "$path")" || return 1
                cp -pR "$lock/uninstall-$tree" "$path" || return 1
            elif [ -f "$lock/uninstall-$tree.absent" ]; then
                rm -rf -- "$path" || return 1
            fi
        done
    fi
    if [ -f "$lock/created_fakes" ]; then
        while IFS= read -r fake; do
            case "$fake" in ''|*[!A-Za-z0-9_.-]*|.*) return 1;; esac
            rm -f "$base/files/fake/$fake" || return 1
        done < "$lock/created_fakes"
        rm -f "$lock/created_fakes" || return 1
    fi
    journal=''
    if [ -f "$lock/changed" ]; then journal=$(cat "$lock/changed") || return 1; fi
    force_restore=0
    # Old recovery snapshots and interactive upstream scripts may bypass our journal.
    if [ ! -f "$lock/changed" ] || [ -f "$lock/foreground" ]; then force_restore=1; fi
    runtime_changed=0
    for idx in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17; do
        managed_path "$idx"
        path=$managed_file
        touched=0
        case "
$journal
" in *"
$path
"*) touched=1;; esac
        different=0
        if [ -f "$lock/$idx" ]; then
            if ! cmp -s "$lock/$idx" "$path"; then different=1; fi
            if [ "$different" = 1 ] || [ "$touched" = 1 ] || [ "$force_restore" = 1 ]; then
                atomic_copy "$lock/$idx" "$path" || return 1
            fi
        elif [ -f "$lock/$idx.absent" ] && { [ -e "$path" ] || [ -L "$path" ]; }; then
            different=1
            rm -f "$path" || return 1
        fi
        case "$idx:$different" in 0:1|1:1|2:1|3:1|6:1|7:1|10:1|11:1|17:1) runtime_changed=1;; esac
    done
    if [ -f "$lock/firewall.restart" ]; then "$root/etc/init.d/firewall" restart || return 1
    elif [ -f "$lock/firewall.touched" ]; then "$root/etc/init.d/firewall" reload || return 1; fi
    if [ -f "$lock/cron.before" ]; then
        atomic_copy "$lock/cron.before" "$root/etc/crontabs/root" || return 1
        "$root/etc/init.d/cron" restart || return 1
    elif [ -f "$lock/cron.absent" ]; then
        rm -f "$root/etc/crontabs/root" || return 1
        "$root/etc/init.d/cron" restart || return 1
    fi
    if [ -x "$init" ]; then
        if [ -f "$lock/enabled" ]; then
            if ! "$init" enabled >/dev/null 2>&1; then service enable || return 1; fi
        elif [ -f "$lock/disabled" ]; then
            if "$init" enabled >/dev/null 2>&1; then service disable || return 1; fi
        fi
        if [ -f "$lock/running" ]; then
            if [ "$force_restore" = 1 ] || [ "$runtime_changed" = 1 ] || [ -f "$lock/service.touched" ] || ! "$init" running >/dev/null 2>&1; then
                service restart || return 1
            fi
        elif [ "$force_restore" = 1 ] || [ -f "$lock/service.touched" ] || "$init" running >/dev/null 2>&1; then
            service stop || return 1
        fi
    fi
    : > "$lock/changed"
    rm -f "$lock/service.touched"
    unset ZM_ROLLBACK
}
finish() {
    rc=$?
    trap - 0
    trap '' INT TERM HUP
    if { [ "$rc" -ne 0 ] || [ "${restore_always:-0}" = 1 ]; } && [ -f "$lock/ready" ]; then
        printf '%s\n' 'zapret-manager: восстановление конфигурации и состояния сервиса' >&2
        if ! reset_all; then
            printf 'zapret-manager: откат не завершён; резервная копия: %s\n' "$lock" >&2
            exit 1
        fi
    fi
    # Only this invocation's fixed lock directory is removed.
    case "$lock" in "$root/tmp/zapret-manager.$profile.lock") rm -rf -- "$lock";; esac
    exit "$rc"
}

case "$action" in
transaction|blockcheck)
    require_root
    if [ "$action" = blockcheck ]; then
        [ -f "$base/blockcheck.sh" ] || fail 'blockcheck.sh не найден'
        [ -x "$init" ] || fail 'служба Zapret не найдена'
        restore_always=1
    fi
    mkdir -p "$root/tmp"
    mkdir "$lock" 2>/dev/null || fail "занято: $lock (после аварии выполните команду recover)"
    trap finish 0
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    printf '%s\n' "$$" > "$lock/pid"
    if [ "$action" = transaction ] && config_unchanged "$@"; then exit 0; fi
    if [ -x "$init" ] && "$init" running >/dev/null 2>&1; then : > "$lock/running"; fi
    if [ -x "$init" ]; then
        if "$init" enabled >/dev/null 2>&1; then : > "$lock/enabled"; else : > "$lock/disabled"; fi
    fi
    snapshot
    : > "$lock/changed"
    if [ "$action" = blockcheck ]; then : > "$lock/foreground"; fi
    : > "$lock/ready"
    ZM_TRANSACTION=$lock
    export ZM_TRANSACTION
    if [ "$action" = blockcheck ]; then
        service stop
        # Foreground execution retains the terminal and its signal delivery.
        # The EXIT trap restores the snapshot even after a successful check.
        /bin/sh "$base/blockcheck.sh"
        exit 0
    fi
    # Keep the supervisor alive so it can roll back a failed or interrupted worker.
    exec 3<&0
    if [ -n "${JZM_BOOTSTRAP:-}" ]; then
        JZM_MODE='command' ucode -S -e "$JZM_BOOTSTRAP" -- "$@" <&3 &
    else
        JZM_MODE='command' ucode -S -L "$ZM_HOME/src/lib" -- "$ZM_HOME/src/main.uc" "$@" <&3 &
    fi
    child=$!
    trap 'kill -TERM "$child" 2>/dev/null || :; wait "$child" 2>/dev/null || :; exit 130' INT
    trap 'kill -TERM "$child" 2>/dev/null || :; wait "$child" 2>/dev/null || :; exit 143' TERM HUP
    wait "$child"
    ;;
recover)
    require_root
    [ -f "$lock/pid" ] || fail 'нет сохранённой транзакции'
    pid=$(cat "$lock/pid")
    case "$pid" in ''|*[!0-9]*) fail 'повреждён pid блокировки';; esac
    if kill -0 "$pid" 2>/dev/null; then fail 'транзакция ещё работает'; fi
    ZM_TRANSACTION=$lock
    if [ -f "$lock/ready" ]; then reset_all || fail "не удалось восстановить $lock"; fi
    rm -rf -- "$lock"
    ;;
reset-config) require_root; reset_config;;
reset)
    require_root
    [ "${ZM_TRANSACTION:-}" = "$lock" ] || fail 'нет активной транзакции'
    reset_all
    ;;
*) fail 'неизвестная операция транзакции';;
esac
