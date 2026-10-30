#!/bin/sh
# JZM_VERSION=0.1.2
# JZM_FORMAT=2
# Generated from src/. This file contains readable shell and ucode source.
set -eu
JZM_PID=$$
export JZM_PID
command -v ucode >/dev/null 2>&1 || {
    printf '%s\n' 'jzm: требуется ucode и пакет ucode-mod-fs' >&2
    exit 127
}
[ "${JZM_MODE:-}" = command ] || [ "$#" -eq 0 ] || {
    printf '%s\n' 'Запустите менеджер без аргументов: jzm' >&2
    exit 2
}
JZM_BACKEND=$(cat <<'__JZM_JZM_BACKEND__'
set -eu
umask 077

fail() { printf 'zapret-manager: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "не найдена команда: $1"; }
[ "$#" -ge 3 ] || fail 'неверный вызов backend'
# Shared dispatcher state is consumed by the scripts sourcing this file.
# shellcheck disable=SC2034
action=$1 root=$2 profile=$3
shift 3
case "$profile" in zapret) ;; *) fail 'неверный профиль';; esac
case "$root" in ''|/*) ;; *) fail 'root должен быть абсолютным';; esac
case "/$root/" in */../*|*/./*) fail 'root содержит . или ..';; esac
base=$root/opt/$profile
confdir=$root/etc/config
config=$confdir/$profile
init=$root/etc/init.d/$profile
# shellcheck disable=SC2034
lock=$root/tmp/zapret-manager.$profile.lock
# shellcheck disable=SC2034
section='@main[0]'
require_root() { [ "$(id -u)" -eq 0 ] || fail 'команда требует root'; }
require_config() { [ -f "$config" ] || fail "не найден конфиг: $config"; need uci; }
uci_cmd() { uci -c "$confdir" -t "${ZM_TRANSACTION:-$root/tmp}/delta" "$@"; }
# All sizes and df values are in KiB. Unknown capacity is a hard failure.
check_space() (
    case "${1:-}" in ''|*[!0-9]*) fail 'check_space: нужен размер в KB';; esac
    [ "${#1}" -le 7 ] && [ "$1" -le 1048576 ] || fail 'check_space: слишком большой размер'
    space_target=$root/overlay
    [ -d "$space_target" ] || space_target=${root:-/}
    space_report=$(df -Pk "$space_target" 2>/dev/null) || fail "не удалось проверить свободное место: $space_target"
    space_free=''
    {
        read -r _space_header || fail "df не вернул заголовок: $space_target"
        read -r _space_fs _space_total _space_used space_free _space_rest || fail "df не вернул доступное место: $space_target"
    } <<EOF
$space_report
EOF
    case "$space_free" in ''|*[!0-9]*) fail "df не вернул доступное место: $space_target";; esac
    space_required=$(( $1 * 2 + 5120 ))
    [ "$space_free" -ge "$space_required" ] || fail "недостаточно места на $space_target: доступно $space_free KB, требуется $space_required KB (запас 5120 KB)"
)
file_kb() { file_bytes=$(wc -c < "$1") || return 1; printf '%s\n' "$(( (file_bytes + 1023) / 1024 ))"; }
mark_changed() {
    if [ "${ZM_ROLLBACK:-0}" != 1 ] && [ "${ZM_TRANSACTION:-}" = "$lock" ]; then
        printf '%s\n' "$1" >> "$lock/changed"
    fi
}
service() {
    [ -x "$init" ] || fail "не найден init-скрипт: $init"
    case "$1" in start|stop|restart)
        if [ "${ZM_ROLLBACK:-0}" != 1 ] && [ "${ZM_TRANSACTION:-}" = "$lock" ]; then
            : > "$lock/service.touched"
            mark_changed "$config"
            mark_changed "$base/config"
        fi;;
    esac
    if [ "$1" = restart ] || [ "$1" = start ]; then
        if [ "$profile" = zapret ] && [ -f "$base/sync_config.sh" ]; then
            /bin/sh "$base/sync_config.sh" || fail 'ошибка sync_config.sh'
        fi
    fi
    "$init" "$1" || fail "сервис $profile: ошибка $1"
}
host_path() {
    case "$1:$profile" in
        user:zapret) host_file=$base/ipset/zapret-hosts-user.txt;;
        exclude:zapret) host_file=$base/ipset/zapret-hosts-user-exclude.txt;;
        google:zapret) host_file=$base/ipset/zapret-hosts-google.txt;;
        *) fail 'неизвестный список доменов';;
    esac
}
# The caller consumes managed_file without a command-substitution subprocess.
# shellcheck disable=SC2034
managed_path() {
    case "$1" in
        0) managed_file=$config;;
        1) host_path user; managed_file=$host_file;;
        2) host_path exclude; managed_file=$host_file;;
        3) host_path google; managed_file=$host_file;;
        4) managed_file=$root/etc/zapret-manager/manager.json;;
        5) managed_file=$root/etc/zapret-manager/flowseal.json;;
        6) managed_file=$root/etc/zapret-manager/devices.txt;;
        7) managed_file=$base/init.d/openwrt/custom.d/20-jzm-exclude.sh;;
        8) managed_file=$root/etc/config/firewall;;
        9) managed_file=$root/etc/zapret-manager/offload.previous;;
        10) managed_file=$base/init.d/openwrt/custom.d/20-script.sh;;
        11) managed_file=$root/etc/zapret-manager/legacy-exclusion-hook.sh;;
        12) managed_file=$root/etc/zapret-manager/state.json;;
        13) managed_file=$root/usr/bin/jzm;;
        14) managed_file=$root/usr/bin/jzm.previous;;
        15) managed_file=$root/etc/zapret-manager/manager-config.json;;
        16) managed_file=$root/etc/zapret-manager/update.json;;
        17) managed_file=$base/config;;
    esac
}
atomic_copy() (
    src=$1 dest=$2
    # Rollback must restore metadata even if only chmod/chown changed.
    if [ "${ZM_ROLLBACK:-0}" != 1 ] && [ "$#" -eq 2 ] && [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$src" "$dest"; then
        exit 0
    fi
    dir=${dest%/*}
    [ -n "$dir" ] || dir=/
    mkdir -p "$dir" || exit 1
    if [ "${ZM_ROLLBACK:-0}" != 1 ]; then check_space "$(file_kb "$src")" || exit 1; fi
    # BusyBox requires the six X characters at the end of the template.
    case "$dest" in */etc/zapret-manager/update.json) tmp=$(mktemp "$dir/.update-XXXXXX") || exit 1;;
        *) tmp=$(mktemp "$dir/.zm-XXXXXX") || exit 1;; esac
    trap 'rm -f "$tmp"' 0
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    # POSIX cp -p preserves metadata without requiring the optional stat applet.
    if [ "${ZM_ROLLBACK:-0}" = 1 ]; then
        cp -p "$src" "$tmp" || exit 1
    else
        if [ -f "$dest" ]; then cp -p "$dest" "$tmp" || exit 1; fi
        cat "$src" > "$tmp" || exit 1
    fi
    if [ "$#" -ge 3 ]; then chmod "$3" "$tmp" || exit 1; fi
    mark_changed "$dest"
    mv -f "$tmp" "$dest"
)


jzm_transaction() {

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

}

jzm_packages() {

package_manager() {
    if command -v apk >/dev/null 2>&1; then manager=apk; extension=apk
    elif command -v opkg >/dev/null 2>&1; then manager=opkg; extension=ipk
    else fail 'не найден opkg или apk'
    fi
}
package_present() {
    if [ "$manager" = apk ]; then apk info -e "$1" >/dev/null 2>&1
    else opkg status "$1" | awk '$1=="Status:" && $NF=="installed" {found=1} END {exit !found}'
    fi
}
install_files() {
    install_kb=0
    for install_file do install_kb=$((install_kb + $(file_kb "$install_file"))); done
    check_space "$install_kb"
    if [ "$manager" = opkg ]; then opkg install "$@"
    else
        printf '%s\n' 'Локальные APK: используется --allow-untrusted для сборки Zapret и LuCI.'
        apk add --allow-untrusted "$@"
    fi
    check_space 0
}
feed_space() {
    if [ "$manager" = opkg ]; then
        package_info=$(opkg info "$@") || fail 'не удалось получить размеры пакетов'
        package_bytes=$(printf '%s\n' "$package_info" | awk '
            /^Size: [0-9]+$/ {sum+=$2; count++}
            END {if (!count) exit 1; printf "%.0f",sum}') || fail 'в метаданных пакетов отсутствует Size'
    else
        package_info=$(apk query --recursive --format json --fields name,installed-size,file-size "$@") || fail 'не удалось получить размеры APK'
        package_bytes=$(printf '%s\n' "$package_info" | ucode -S -e '
            import { stdin } from "fs";
            let list=json(stdin.read("all")), total=0;
            if (type(list)!="array" || !length(list)) die("APK: нет размеров пакетов");
            for (let p in list) {
                let installed=p["installed-size"], file=p["file-size"];
                if (type(installed)!="int" || type(file)!="int" || installed<0 || file<0) die("APK: неверный размер");
                total += installed > file ? installed : file;
            }
            printf("%.0f",total);
        ') || fail 'не удалось проверить размеры APK'
    fi
    case "$package_bytes" in ''|*[!0-9]*) fail 'неверный размер пакета';; esac
    check_space "$(( (package_bytes + 1023) / 1024 ))"
}
luci_ready() {
    if [ -x "$root/etc/init.d/rpcd" ]; then "$root/etc/init.d/rpcd" restart; fi
    printf '%s\n' 'LuCI Zapret установлен. Обновите страницу LuCI: Сервисы → Zapret.'
}

case "$action" in
release-install)
    require_root
    [ -z "${ZM_TRANSACTION:-}" ] || fail 'пакеты нельзя устанавливать внутри транзакции конфигов'
    [ -z "$root" ] || fail 'установка релиза возможна только на роутере'
    need curl
    package_manager
    components=$5
    case "$components" in both|luci) ;; *) fail 'неверный набор пакетов';; esac
    check_space "${6:-16384}"
    if ! command -v unzip >/dev/null 2>&1; then
        check_space 0
        "$manager" update
        feed_space unzip
        if [ "$manager" = opkg ]; then opkg install unzip; else apk add unzip; fi
        check_space 0
    fi
    stage=$(mktemp -d /tmp/zm-release-XXXXXX)
    trap 'rm -rf -- "$stage"' 0
    curl --fail --location --show-error --proto '=https' --proto-redir '=https' \
        --connect-timeout "$3" --max-time "$4" --max-filesize 16777216 --output "$stage/release.zip" "$1"
    if [ -n "$2" ]; then
        need sha256sum
        printf '%s  %s\n' "$2" "$stage/release.zip" | sha256sum -c - || fail 'SHA256 архива не совпал'
    fi
    unzip -l "$stage/release.zip" > "$stage/members"
    set --
    # Validate and extract every selected package before invoking the package manager.
    for name in zapret luci-app-zapret; do
        [ "$components:$name" != luci:zapret ] || continue
        if [ "$manager" = opkg ]; then pattern="^${name}_[A-Za-z0-9_.+-]+[.]ipk$"
        else pattern="^apk/${name}-[A-Za-z0-9_.+-]+[.]apk$"
        fi
        member=$(awk -v pattern="$pattern" '$4 ~ pattern && $1+0>0 && $1+0<=16777216 {print $4}' "$stage/members")
        [ "$(printf '%s\n' "$member" | wc -l)" -eq 1 ] && [ -n "$member" ] || fail "в релизе не найден единственный пакет $name"
        package=$stage/$(basename "$member")
        unzip -p "$stage/release.zip" "$member" > "$package"
        [ -s "$package" ] && [ "$(wc -c < "$package")" -le 16777216 ] || fail "неверный размер пакета $name"
        set -- "$@" "$package"
    done
    install_files "$@"
    luci_ready
    ;;
package)
    require_root
    [ -z "${ZM_TRANSACTION:-}" ] || fail 'пакеты нельзя изменять внутри транзакции конфигов'
    [ -z "$root" ] || fail 'установка пакетов возможна только при root="/"'
    verb=$1; shift
    package_manager
    for pkg in "$@"; do
        case "$(basename "$pkg")" in
            zapret[_-]*."$extension"|luci-app-zapret[_-]*."$extension") ;;
            *) fail "неверный пакет для $manager: $pkg";;
        esac
        [ -f "$pkg" ] || fail "пакет не найден: $pkg"
    done
    case "$verb" in
    install|update)
        check_space 0
        if [ "$#" -gt 0 ]; then
            stage=$(mktemp -d /tmp/zm-local-XXXXXX)
            trap 'rm -rf -- "$stage"' 0
            for pkg in "$@"; do cp "$pkg" "$stage/$(basename "$pkg")"; done
            install_files "$stage/"*."$extension"
        else
            "$manager" update
            if [ "$verb" = install ]; then
                feed_space zapret luci-app-zapret
                if [ "$manager" = opkg ]; then opkg install zapret luci-app-zapret
                else apk add zapret luci-app-zapret; fi
            else
                if [ "$manager" = opkg ]; then
                    pending=$(opkg list-upgradable)
                    pending=$(printf '%s\n' "$pending" | awk '$1=="zapret" || $1=="luci-app-zapret" {print $1}')
                else
                    pending=$(apk version -l '<' zapret luci-app-zapret)
                    pending=$(printf '%s\n' "$pending" | awk '
                        $1 ~ /^zapret-[0-9]/ {print "zapret"}
                        $1 ~ /^luci-app-zapret-[0-9]/ {print "luci-app-zapret"}')
                fi
                changed=0
                for name in zapret luci-app-zapret; do
                    if ! package_present "$name"; then
                        feed_space "$name"
                        if [ "$manager" = opkg ]; then opkg install "$name"; else apk add "$name"; fi
                        check_space 0
                        changed=1
                    elif printf '%s\n' "$pending" | awk -v name="$name" '$0==name {found=1} END{exit !found}'; then
                        feed_space "$name"
                        if [ "$manager" = opkg ]; then opkg upgrade "$name"; else apk upgrade "$name"; fi
                        check_space 0
                        changed=1
                    fi
                done
                if [ "$changed" = 0 ]; then
                    printf '%s\n' 'Zapret и LuCI актуальны. Новых версий нет, переустановка не требуется.'
                    exit 0
                fi
            fi
        fi
        check_space 0
        if package_present luci-app-zapret; then luci_ready
        else fail 'Zapret установлен, но luci-app-zapret отсутствует; установка не завершена'
        fi
        ;;
    remove)
        if [ -x "$init" ]; then service stop; service disable; fi
        set --
        for name in luci-app-zapret zapret; do if package_present "$name"; then set -- "$@" "$name"; fi; done
        if [ "$#" -gt 0 ]; then
            if [ "$manager" = opkg ]; then opkg remove "$@"; else apk del "$@"; fi
        fi
        ;;
    *) fail 'неверная операция пакета';;
    esac
    ;;
*) fail 'неизвестная операция пакета';;
esac

}

jzm_network() {

case "$action" in
network)
    need uci
    [ -f "$confdir/firewall" ] && [ -x "$root/etc/init.d/firewall" ] || fail 'firewall OpenWrt не найден'
    uci_cmd -q get 'firewall.@defaults[0]' >/dev/null || fail 'не найдена основная секция firewall'
    if [ "$1" = status ]; then
        printf 'Программный Flow Offloading: %s\n' "$(uci_cmd -q get 'firewall.@defaults[0].flow_offloading' || printf 0)"
        printf 'Аппаратный Flow Offloading: %s\n' "$(uci_cmd -q get 'firewall.@defaults[0].flow_offloading_hw' || printf 0)"
        if [ "$(uci_cmd -q get firewall.jzm_quic.name || :)" = JZM_Block_QUIC ]; then printf 'QUIC: заблокирован JZM\n'; else printf 'QUIC: JZM не блокирует\n'; fi
        exit 0
    fi
    require_root
    [ "${ZM_TRANSACTION:-}" = "$lock" ] || fail 'нет активной транзакции'
    : > "$lock/firewall.touched"
    case "$1:${2:-}" in
    offload:disable)
        saved=$root/etc/zapret-manager/offload.previous
        if [ ! -f "$saved" ]; then
            printf '%s\n%s\n' "$(uci_cmd -q get 'firewall.@defaults[0].flow_offloading' || printf x)" \
                "$(uci_cmd -q get 'firewall.@defaults[0].flow_offloading_hw' || printf x)" > "$lock/offload.values"
            atomic_copy "$lock/offload.values" "$saved"
        fi
        if [ "$(uci_cmd -q get 'firewall.@defaults[0].flow_offloading' || printf x)" != 0 ] ||
            [ "$(uci_cmd -q get 'firewall.@defaults[0].flow_offloading_hw' || printf x)" != 0 ]; then
            : > "$lock/firewall.restart"
        fi
        uci_cmd set 'firewall.@defaults[0].flow_offloading=0'
        uci_cmd set 'firewall.@defaults[0].flow_offloading_hw=0'
        ;;
    offload:restore)
        saved=$root/etc/zapret-manager/offload.previous
        [ -f "$saved" ] || fail 'сохранённых параметров Flow Offloading нет'
        sw=$(sed -n '1p' "$saved"); hw=$(sed -n '2p' "$saved")
        for value in "$sw" "$hw"; do case "$value" in 0|1|x) ;; *) fail 'повреждены сохранённые параметры';; esac; done
        if [ "$(uci_cmd -q get 'firewall.@defaults[0].flow_offloading' || printf x)" != "$sw" ] ||
            [ "$(uci_cmd -q get 'firewall.@defaults[0].flow_offloading_hw' || printf x)" != "$hw" ]; then
            : > "$lock/firewall.restart"
        fi
        if [ "$sw" = x ]; then uci_cmd -q delete 'firewall.@defaults[0].flow_offloading' || :
        else uci_cmd set "firewall.@defaults[0].flow_offloading=$sw"; fi
        if [ "$hw" = x ]; then uci_cmd -q delete 'firewall.@defaults[0].flow_offloading_hw' || :
        else uci_cmd set "firewall.@defaults[0].flow_offloading_hw=$hw"; fi
        mark_changed "$saved"
        rm -f "$saved"
        ;;
    quic:on|quic:off)
        existing=$(uci_cmd -q get firewall.jzm_quic.name || :)
        [ -z "$existing" ] || [ "$existing" = JZM_Block_QUIC ] || fail 'имя правила jzm_quic уже занято'
        if [ "$2" = off ]; then uci_cmd -q delete firewall.jzm_quic || :
        else
            uci_cmd set firewall.jzm_quic=rule
            uci_cmd set firewall.jzm_quic.name=JZM_Block_QUIC
            uci_cmd set firewall.jzm_quic.src=lan
            uci_cmd set firewall.jzm_quic.dest=wan
            uci_cmd set firewall.jzm_quic.proto=udp
            uci_cmd set 'firewall.jzm_quic.dest_port=80 443'
            uci_cmd set firewall.jzm_quic.target=REJECT
            uci_cmd set firewall.jzm_quic.family=any
        fi
        ;;
    *) fail 'неверная настройка совместимости';;
    esac
    mark_changed "$confdir/firewall"
    uci_cmd commit firewall
    if [ -f "$lock/firewall.restart" ]; then "$root/etc/init.d/firewall" restart
    else "$root/etc/init.d/firewall" reload; fi
    ;;
*) fail 'неизвестная операция сети';;
esac

}

jzm_uninstall() {

require_root
[ "${ZM_TRANSACTION:-}" = "$lock" ] || fail 'нет активной транзакции удаления'
case "${1:-}" in manager|all) mode=$1;; *) fail 'ожидается manager или all';; esac
state=$root/etc/zapret-manager
# Snapshot complete trees, including backups and downloaded catalogs, before deletion.
for tree in state zapret; do
    [ "$tree" != zapret ] || [ "$mode" = all ] || continue
    if [ "$tree" = state ]; then path=$state; else path=$base; fi
    [ ! -L "$path" ] || fail "отказ удалять символическую ссылку: $path"
    if [ -d "$path" ]; then cp -pR "$path" "$lock/uninstall-$tree"
    else : > "$lock/uninstall-$tree.absent"; fi
done
: > "$lock/uninstall.ready"

saved=$state/offload.previous
if [ -f "$saved" ]; then
    sw=$(sed -n '1p' "$saved"); hw=$(sed -n '2p' "$saved")
    for value in "$sw" "$hw"; do case "$value" in 0|1|x) ;; *) fail 'повреждены сохранённые параметры Flow Offloading';; esac; done
    for option in flow_offloading flow_offloading_hw; do
        if [ "$option" = flow_offloading ]; then value=$sw; else value=$hw; fi
        current=$(uci_cmd -q get "firewall.@defaults[0].$option" || printf x)
        [ "$current" = "$value" ] || : > "$lock/firewall.restart"
        if [ "$value" = x ]; then uci_cmd -q delete "firewall.@defaults[0].$option" || :
        else uci_cmd set "firewall.@defaults[0].$option=$value"; fi
    done
    : > "$lock/firewall.touched"
fi
if [ -f "$confdir/firewall" ] && [ "$(uci_cmd -q get firewall.jzm_quic.name || :)" = JZM_Block_QUIC ]; then
    uci_cmd delete firewall.jzm_quic
    : > "$lock/firewall.touched"
fi
if [ -f "$lock/firewall.touched" ]; then
    mark_changed "$confdir/firewall"
    uci_cmd commit firewall
    if [ -f "$lock/firewall.restart" ]; then "$root/etc/init.d/firewall" restart
    else "$root/etc/init.d/firewall" reload; fi
fi

cronfile=$root/etc/crontabs/root
tag='# zapret-manager:zapret'
if [ -f "$cronfile" ] && grep -q "$tag$" "$cronfile"; then
    cp -p "$cronfile" "$lock/cron.before"
    awk -v tag="$tag" 'length($0)<length(tag) || substr($0,length($0)-length(tag)+1)!=tag' "$cronfile" > "$lock/cron.after"
    atomic_copy "$lock/cron.after" "$cronfile"
    "$root/etc/init.d/cron" restart
fi

hook=$base/init.d/openwrt/custom.d/20-jzm-exclude.sh
if [ "$mode" = manager ]; then
    if [ -e "$hook" ] || [ -L "$hook" ]; then
        mark_changed "$hook"
        rm -f "$hook"
        if [ -f "$state/legacy-exclusion-hook.sh" ]; then
            legacy=$base/init.d/openwrt/custom.d/20-script.sh
            [ ! -e "$legacy" ] || fail 'старый хук уже существует; удаление отменено'
            atomic_copy "$state/legacy-exclusion-hook.sh" "$legacy"
        fi
        if [ -x "$init" ] && "$init" running >/dev/null 2>&1; then service restart; fi
    fi
else
    mark_changed "$config"
    rm -f "$config"
    # Both paths are fixed whitelist roots; package removal has already succeeded.
    rm -rf -- "$base"
fi
mark_changed "$root/usr/bin/jzm"
mark_changed "$root/usr/bin/jzm.previous"
rm -f "$root/usr/bin/jzm" "$root/usr/bin/jzm.previous"
rm -rf -- "$state"

}

# ---- system operation dispatcher ----

case "$action" in
uninstall-cleanup)
    jzm_uninstall "$@"
    ;;
check-space) check_space "$1";;
manager-uninstall)
    require_root
    mark_changed "$root/usr/bin/jzm"
    mark_changed "$root/usr/bin/jzm.previous"
    rm -f "$root/usr/bin/jzm" "$root/usr/bin/jzm.previous"
    ;;
manager-validate)
    /bin/sh -n "$1"
    JZM_MODE='command' /bin/sh "$1" version
    ;;
manager-install|manager-config-init)
    require_root
    destination=$2
    case "$destination" in ''|/*) ;; *) fail 'нужен абсолютный путь установки';; esac
    case "/$destination/" in */../*|*/./*) fail 'неверный путь установки';; esac
    if [ "$action" = manager-install ]; then
        target=$destination/usr/bin/jzm
        /bin/sh -n "$1" || fail 'ошибка синтаксиса обновления'
        if [ -f "$target" ]; then atomic_copy "$target" "$target.previous" 755; fi
        atomic_copy "$1" "$target" 755
    else
        target=$destination/etc/zapret-manager/manager-config.json
        if [ ! -e "$target" ]; then atomic_copy "$1" "$target"; fi
    fi
    ;;
network)
    jzm_network "$@"
    ;;
architecture)
    awk -F "'" '/^DISTRIB_ARCH=/{print $2; found=1; exit} END{if(!found)exit 1}' "$root/etc/openwrt_release" > "$1"
    ;;
status-read)
    if [ ! -x "$init" ]; then printf 'missing\n' > "$1"
    elif "$init" running >/dev/null 2>&1; then printf 'running\n' > "$1"
    else printf 'stopped\n' > "$1"
    fi
    ;;
source-write)
    require_root
    case "$2" in manager|flowseal) ;; *) fail 'неизвестный источник';; esac
    atomic_copy "$1" "$root/etc/zapret-manager/$2.json"
    ;;
device-hook-write)
    require_root
    [ "$profile" = zapret ] || fail 'нужен профиль Zapret'
    if [ "${2:-}" = migrate ]; then
        legacy=$base/init.d/openwrt/custom.d/20-script.sh
        saved=$root/etc/zapret-manager/legacy-exclusion-hook.sh
        [ -e "$saved" ] || atomic_copy "$legacy" "$saved"
        mark_changed "$legacy"
        rm -f "$legacy"
    fi
    atomic_copy "$1" "$base/init.d/openwrt/custom.d/20-jzm-exclude.sh"
    mark_changed "$base/init.d/openwrt/custom.d/20-jzm-exclude.sh"
    chmod 755 "$base/init.d/openwrt/custom.d/20-jzm-exclude.sh"
    ;;
strategy-state-clear)
    require_root
    mark_changed "$root/etc/zapret-manager/state.json"
    rm -f "$root/etc/zapret-manager/state.json"
    ;;
state-write)
    require_root
    case "$2" in ''|*[!A-Za-z0-9_.-]*|.*) fail 'неверное имя файла';; esac
    atomic_copy "$1" "$root/etc/zapret-manager/$2"
    ;;
resource-write)
    require_root
    case "$2" in ''|*[!A-Za-z0-9_.-]*|.*) fail 'неверное имя ресурса';; esac
    case "$2" in *.bin) ;; *) fail 'ожидается bin-ресурс';; esac
    [ -s "$1" ] || fail 'пустой bin-ресурс'
    [ "${ZM_TRANSACTION:-}" = "$lock" ] || fail 'нет активной транзакции для fake-файла'
    if [ ! -e "$base/files/fake/$2" ]; then
        check_space "$(file_kb "$1")"
        printf '%s\n' "$2" >> "$lock/created_fakes"
        atomic_copy "$1" "$base/files/fake/$2"
    fi
    ;;
release-install)
    jzm_packages "$@"
    ;;
transaction|recover|reset-config|reset|blockcheck)
    jzm_transaction "$@"
    ;;
status)
    if [ ! -x "$init" ]; then printf '%s: not installed\n' "$profile"
    elif "$init" running >/dev/null 2>&1; then printf '%s: running\n' "$profile"
    else printf '%s: stopped\n' "$profile"
    fi
    ;;
doctor)
    errors=0
    for tool in ucode uci curl mktemp sha256sum; do
        if command -v "$tool" >/dev/null 2>&1; then printf 'OK %s\n' "$tool"
        else printf 'MISSING %s\n' "$tool"; errors=$((errors + 1))
        fi
    done
    if ! command -v opkg >/dev/null 2>&1 && ! command -v apk >/dev/null 2>&1; then
        printf '%s\n' 'MISSING opkg/apk'; errors=$((errors + 1))
    fi
    [ -f "$config" ] || { printf 'MISSING %s\n' "$config"; errors=$((errors + 1)); }
    [ -x "$init" ] || { printf 'MISSING %s\n' "$init"; errors=$((errors + 1)); }
    [ "$errors" -eq 0 ]
    ;;
service)
    require_root
    case "${1:-}" in start|stop|restart|enable|disable) service "$1";; *) fail 'неверное действие сервиса';; esac
    ;;
config-read|config-read-optional)
    require_config
    if [ "$action" = config-read-optional ]; then
        uci_cmd -q get "$profile.$section" >/dev/null || fail 'основная секция конфига не найдена'
        uci_cmd -q get "$profile.$section.$1" || :
    else uci_cmd -q get "$profile.$section.$1"; fi
    ;;
config-get)
    require_config
    uci_cmd -q get "$profile.$section.$2" > "$1"
    ;;
config-get-optional)
    require_config
    uci_cmd -q get "$profile.$section" > /dev/null || fail 'основная секция конфига не найдена'
    if ! uci_cmd -q get "$profile.$section.$2" > "$1"; then : > "$1"; fi
    ;;
config-set)
    require_root; require_config
    [ "$#" -gt 0 ] && [ "$(( $# % 2 ))" -eq 0 ] || fail 'нужны пары опция/значение'
    key=1
    for value do
        if [ "$key" = 1 ]; then
            case "$value" in *[!A-Za-z0-9_]*|'') fail 'неверное имя опции';; esac
            key=0
        else key=1; fi
    done
    while [ "$#" -gt 0 ]; do
        uci_cmd set "$profile.$section.$1=$2"
        shift 2
    done
    mark_changed "$config"
    uci_cmd commit "$profile"
    ;;
config-restore)
    require_root; need uci
    # Parse in an isolated UCI directory before touching the active configuration.
    stage=$(mktemp -d "$root/tmp/zm-uci-XXXXXX")
    trap 'rm -rf -- "$stage"' 0
    cp "$1" "$stage/$profile"
    uci -c "$stage" -t "$stage/delta" show "$profile" >/dev/null || fail 'резервная копия содержит неверный UCI'
    expected_type=main
    [ "$(uci -c "$stage" -t "$stage/delta" -q get "$profile.$section")" = "$expected_type" ] || fail 'в резервной копии нет основной UCI-секции'
    atomic_copy "$stage/$profile" "$config"
    ;;
hosts-read-stdout)
    host_path "$1"
    path=$host_file
    if [ -f "$path" ]; then cat "$path"; fi
    ;;
hosts-read)
    host_path "$2"
    path=$host_file
    if [ -f "$path" ]; then cat "$path" > "$1"; else : > "$1"; fi
    ;;
hosts-write)
    require_root
    host_path "$2"
    atomic_copy "$1" "$host_file"
    ;;
backup-write)
    require_root
    [ ! -e "$2" ] || fail 'файл резервной копии уже существует'
    case "$2" in *[!A-Za-z0-9_./\ -]*|*/../*|*/./*) fail 'неверный путь резервной копии';; esac
    case "$2" in "$root/tmp/"*|"$root/etc/zapret-manager/backups/"*) ;; *) fail 'копия разрешена только в backups/ или /tmp/';; esac
    dir=$(dirname "$2")
    mkdir -p "$dir"
    physical=$(CDPATH='' cd -P "$dir" && pwd)
    case "$physical/" in "$root/tmp/"*|"$root/etc/zapret-manager/backups/"*) ;; *) fail 'каталог копии выходит за разрешённые пути';; esac
    tmp=$(mktemp "$dir/.zm-backup-XXXXXX")
    trap 'rm -f "$tmp"' 0
    cat "$1" > "$tmp"
    # A hard link publishes the complete file and refuses to replace an existing backup.
    ln "$tmp" "$2"
    ;;
github-download)
    need curl
    case "$5" in https://api.github.com/*) ;; *) fail 'неверный адрес GitHub API';; esac
    trap 'rm -f "$1.body" "$1.headers"' 0
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    # Keep HTTP error bodies: --fail would hide the API's explanation.
    code=$(curl --silent --show-error --location --max-redirs 3 \
        --proto '=https' --proto-redir '=https' --connect-timeout "$2" \
        --max-time "$3" --max-filesize "$4" --output "$1.body" \
        --dump-header "$1.headers" --write-out '%{http_code}' "$5")
    remaining=$(awk '/^HTTP\// {value=""} tolower($1)=="x-ratelimit-remaining:" {value=$2; gsub(/\r/, "", value)} END {print value}' "$1.headers")
    printf '%s\n%s\n' "$code" "$remaining" > "$1"
    cat "$1.body" >> "$1"
    ;;
download)
    need curl
    curl --fail --silent --show-error --location --max-redirs 3 \
        --proto '=https' --proto-redir '=https' --connect-timeout "$2" \
        --max-time "$3" --max-filesize "$4" --output "$1" "$5"
    ;;
probe)
    need curl
    curl --fail --silent --show-error --location --max-redirs 3 \
        --proto '=http,https' --proto-redir '=http,https' --connect-timeout "$1" \
        --max-time "$2" --output /dev/null "$3"
    ;;
settle) sleep "$1";;
package)
    jzm_packages "$@"
    ;;
schedule)
    require_root
    settings=$1; shift
    cronfile=$root/etc/crontabs/root
    [ -x "$root/etc/init.d/cron" ] || fail 'не найден cron'
    mkdir -p "$(dirname "$cronfile")"
    tmp=$(mktemp "$root/tmp/zm-cron-XXXXXX")
    trap 'rm -f "$tmp"' 0
    tag="# zapret-manager:$profile"
    if [ -f "$cronfile" ]; then
        awk -v tag="$tag" 'length($0)<length(tag) || substr($0,length($0)-length(tag)+1)!=tag' "$cronfile" > "$tmp"
    fi
    if [ "$1" != off ]; then
        hour=$1; targets=$2; strategies=$3
        for path in "$settings" "$targets" "$strategies"; do
            case "$path" in /*) ;; *) fail 'для расписания нужны абсолютные пути';; esac
            case "$path" in *[!A-Za-z0-9_./-]*) fail 'пути cron: только буквы, цифры, / . _ -';; esac
        done
        printf '0 %s * * * JZM_MODE=command /bin/sh %s/usr/bin/jzm --config %s auto-best %s %s >%s/tmp/zapret-manager.log 2>&1 %s\n' \
            "$hour" "$root" "$settings" "$targets" "$strategies" "$root" "$tag" >> "$tmp"
    fi
    if [ -f "$cronfile" ]; then cp -p "$cronfile" "$ZM_TRANSACTION/cron.before"; else : > "$ZM_TRANSACTION/cron.absent"; fi
    atomic_copy "$tmp" "$cronfile"
    if ! "$root/etc/init.d/cron" restart; then
        if [ -f "$ZM_TRANSACTION/cron.before" ]; then atomic_copy "$ZM_TRANSACTION/cron.before" "$cronfile"
        else rm -f "$cronfile"
        fi
        fail 'cron: ошибка перезапуска'
    fi
    ;;
*) fail "неизвестное действие backend: $action";;
esac
__JZM_JZM_BACKEND__
)
export JZM_BACKEND

JZM_UCODE_1=$(cat <<'__JZM_JZM_UCODE_1__'
import * as fs from 'fs';
const EMBEDDED_STRATEGIES = `
#v1
--filter-tcp=443
--hostlist-exclude=/opt/zapret/ipset/zapret-hosts-user-exclude.txt
--dpi-desync=split2
--dpi-desync-split-seqovl=681
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/stun.bin
#v2
--filter-tcp=443
--hostlist-exclude=/opt/zapret/ipset/zapret-hosts-user-exclude.txt
--dpi-desync=fake,multisplit
--dpi-desync-split-seqovl=681
--dpi-desync-split-pos=1
--dpi-desync-fooling=ts
--dpi-desync-repeats=8
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/stun.bin
--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com
#v3
--filter-tcp=443
--hostlist-exclude=/opt/zapret/ipset/zapret-hosts-user-exclude.txt
--dpi-desync=hostfakesplit
--dpi-desync-hostfakesplit-mod=host=ozon.ru
--dpi-desync-repeats=4
--dpi-desync-fooling=ts,md5sig
--dpi-desync-badseq-increment=0
#v4
--filter-tcp=443
--hostlist-exclude=/opt/zapret/ipset/zapret-hosts-user-exclude.txt
--dpi-desync=multisplit
--dpi-desync-split-seqovl=582
--dpi-desync-split-pos=1
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/stun.bin
#v5
--filter-tcp=443
--hostlist-exclude=/opt/zapret/ipset/zapret-hosts-user-exclude.txt
--dpi-desync=fake,fakeddisorder
--dpi-desync-split-pos=1
--dpi-desync-fake-tls=/opt/zapret/files/fake/stun.bin
--dpi-desync-fake-tls-mod=none
--dpi-desync-fakedsplit-pattern=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
--dpi-desync-fooling=badseq,badsum
--dpi-desync-badseq-increment=0
#v6
--filter-tcp=443
--hostlist-exclude=/opt/zapret/ipset/zapret-hosts-user-exclude.txt
--dpi-desync=hostfakesplit
--dpi-desync-hostfakesplit-mod=host=i2.photo.2gis.com
--dpi-desync-hostfakesplit-midhost=host-2
--dpi-desync-split-seqovl=726
--dpi-desync-fooling=badsum,badseq
--dpi-desync-badseq-increment=0
#v7
--filter-tcp=443
--hostlist-exclude=/opt/zapret/ipset/zapret-hosts-user-exclude.txt
--dpi-desync=fake,multisplit
--dpi-desync-split-seqovl=654
--dpi-desync-split-pos=1
--dpi-desync-fooling=badseq,badsum
--dpi-desync-repeats=8
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/stun.bin
--dpi-desync-fake-tls=/opt/zapret/files/fake/stun.bin
--dpi-desync-badseq-increment=0
#v8
--filter-tcp=443
--hostlist-exclude=/opt/zapret/ipset/zapret-hosts-user-exclude.txt
--dpi-desync=fake
--dpi-desync-fooling=ts
--dpi-desync-fake-tls=/opt/zapret/files/fake/4pda.bin
--dpi-desync-fake-tls-mod=none
#v9
--filter-tcp=443
--hostlist-exclude=/opt/zapret/ipset/zapret-hosts-user-exclude.txt
--dpi-desync=hostfakesplit
--dpi-desync-fooling=badseq,badsum
--dpi-desync-hostfakesplit-mod=host=ozon.ru
--dpi-desync-badseq-increment=0
#v10
--filter-tcp=443
--hostlist-exclude=/opt/zapret/ipset/zapret-hosts-user-exclude.txt
--dpi-desync=fake,split2
--dpi-desync-split-pos=2
--dpi-desync-fake-tls=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
--dpi-desync-hostfakesplit-mod=host=maxcdn.bootstrapcdn.com
--dpi-desync-fake-tls-mod=rnd,sni=maxcdn.bootstrapcdn.com
--dpi-desync-fooling=ts
#Dv1
--filter-tcp=2053,2083,2087,2096,8443
--hostlist-domains=discord.media
--dpi-desync=multisplit
--dpi-desync-split-seqovl=652
--dpi-desync-split-pos=2
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
#Dv2
--filter-tcp=2053,2083,2087,2096,8443
--hostlist-domains=discord.media
--dpi-desync=fake,multisplit
--dpi-desync-split-seqovl=681
--dpi-desync-split-pos=1
--dpi-desync-fooling=ts
--dpi-desync-repeats=8
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com
#Dv3
--filter-tcp=2053,2083,2087,2096,8443
--hostlist-domains=discord.media
--dpi-desync=fake
--dpi-desync-repeats=6
--dpi-desync-fooling=ts
--dpi-desync-fake-tls=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
--dpi-desync-fake-tls-mod=none
#Dv4
--filter-tcp=2053,2083,2087,2096,8443
--hostlist-domains=discord.media
--dpi-desync=multisplit
--dpi-desync-split-seqovl=652
--dpi-desync-split-pos=2
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
#Dv5
--filter-tcp=2053,2083,2087,2096,8443
--hostlist-domains=discord.media
--dpi-desync=fake,multisplit
--dpi-desync-repeats=6
--dpi-desync-fooling=badseq
--dpi-desync-badseq-increment=1000
--dpi-desync-fake-tls=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
#Dv6
--filter-tcp=2053,2083,2087,2096,8443
--hostlist-domains=discord.media
--dpi-desync=multisplit
--dpi-desync-split-seqovl=681
--dpi-desync-split-pos=1
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
#Dv7
--filter-tcp=2053,2083,2087,2096,8443
--hostlist-domains=discord.media
--dpi-desync=multisplit
--dpi-desync-split-pos=2,sniext+1
--dpi-desync-split-seqovl=679
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
#Dv8
--filter-tcp=2053,2083,2087,2096,8443
--hostlist-domains=discord.media
--dpi-desync=fake
--dpi-desync-fake-tls-mod=none
--dpi-desync-repeats=6
--dpi-desync-fooling=badseq
--dpi-desync-badseq-increment=2
#Dv9
--filter-tcp=2053,2083,2087,2096,8443
--hostlist-domains=discord.media
--dpi-desync=fake,fakedsplit
--dpi-desync-split-pos=1
--dpi-desync-fooling=badseq
--dpi-desync-badseq-increment=2
--dpi-desync-repeats=8
--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com
#Dv10
--filter-tcp=2053,2083,2087,2096,8443
--hostlist-domains=discord.media
--dpi-desync=fake,multisplit
--dpi-desync-split-seqovl=681
--dpi-desync-split-pos=1
--dpi-desync-fooling=badseq
--dpi-desync-badseq-increment=10000000
--dpi-desync-repeats=8
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com
#Dv11
--filter-tcp=2053,2083,2087,2096,8443
--hostlist-domains=discord.media
--dpi-desync=fake,multisplit
--dpi-desync-split-seqovl=681
--dpi-desync-split-pos=1
--dpi-desync-fooling=ts
--dpi-desync-repeats=8
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com
#Dv12
--filter-tcp=2053,2083,2087,2096,8443
--hostlist-domains=discord.media
--dpi-desync=fake
--dpi-desync-repeats=6
--dpi-desync-fooling=badseq
--dpi-desync-badseq-increment=2
--dpi-desync-fake-tls=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
#Dv13
--filter-tcp=2053,2083,2087,2096,8443
--hostlist-domains=discord.media
--dpi-desync=fake
--dpi-desync-repeats=6
--dpi-desync-fooling=ts
--dpi-desync-fake-tls=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
#Dv14
--filter-tcp=2053,2083,2087,2096,8443
--hostlist-domains=discord.media
--dpi-desync=fake,fakedsplit
--dpi-desync-repeats=6
--dpi-desync-fooling=ts
--dpi-desync-fakedsplit-pattern=0x00
--dpi-desync-fake-tls=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
#Dv15
--filter-tcp=2053,2083,2087,2096,8443
--hostlist-domains=discord.media
--dpi-desync=fake,multidisorder
--dpi-desync-split-pos=1,midsld
--dpi-desync-repeats=11
--dpi-desync-fooling=badseq
--dpi-desync-fake-tls=0x00000000
--dpi-desync-fake-tls=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com
#Dv16
--filter-tcp=2053,2083,2087,2096,8443
--hostlist-domains=discord.media
--dpi-desync=fake,hostfakesplit
--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com
--dpi-desync-hostfakesplit-mod=host=www.google.com,altorder=1
--dpi-desync-fooling=ts
#Dv17
--filter-tcp=2053,2083,2087,2096,8443
--hostlist-domains=discord.media
--dpi-desync=hostfakesplit
--dpi-desync-repeats=4
--dpi-desync-fooling=ts
--dpi-desync-hostfakesplit-mod=host=www.google.com
#Yv01
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--ip-id=zero
--dpi-desync=multisplit
--dpi-desync-split-seqovl=681
--dpi-desync-split-pos=1
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
#Yv02
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=multisplit
--dpi-desync-split-pos=1,sniext+1
--dpi-desync-split-seqovl=1
#Yv03
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=fake,multisplit
--dpi-desync-split-pos=2,sld
--dpi-desync-fake-tls=0x0F0F0F0F
--dpi-desync-fake-tls=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
--dpi-desync-fake-tls-mod=rnd,dupsid,sni=ggpht.com
--dpi-desync-split-seqovl=620
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
--dpi-desync-fooling=badsum,badseq
#Yv04
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=split2
--dpi-desync-split-seqovl=681
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
#Yv05
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=fake,fakeddisorder
--dpi-desync-split-pos=10,midsld
--dpi-desync-fake-tls=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
--dpi-desync-fake-tls-mod=rnd,dupsid,sni=fonts.google.com
--dpi-desync-fake-tls=0x0F0F0F0F
--dpi-desync-fake-tls-mod=none
--dpi-desync-fakedsplit-pattern=/opt/zapret/files/fake/tls_clienthello_vk_com.bin
--dpi-desync-split-seqovl=336
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/tls_clienthello_gosuslugi_ru.bin
--dpi-desync-fooling=badseq,badsum
--dpi-desync-badseq-increment=0
#Yv06
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=multidisorder
--dpi-desync-split-pos=7,sld+1
--dpi-desync-fake-tls=0x0F0F0F0F
--dpi-desync-fake-tls=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com
--dpi-desync-fooling=badseq
--dpi-desync-autottl=2:2-12
#Yv07
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=multidisorder
--dpi-desync-split-pos=1,midsld,endhost-1
--dpi-desync-repeats=2
--dpi-desync-fooling=md5sig
--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com
#Yv08
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=hostfakesplit
--dpi-desync-hostfakesplit-mod=host=google.com
--dpi-desync-fooling=ts
#Yv09
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync-repeats=6
--dpi-desync-fooling=badseq
--dpi-desync-badseq-increment=2
--dpi-desync=multidisorder
--dpi-desync-split-pos=1,midsld
--dpi-desync-fake-quic=/opt/zapret/files/fake/quic_initial_www_google_com.bin
#Yv10
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=multisplit
--dpi-desync-split-pos=1,2
--dpi-desync-split-seqovl=4
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com
#Yv11
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=multidisorder
--dpi-desync-split-pos=2,5,105,host+5,sld-1,endsld-5,endsld
#Yv12
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=multidisorder
--dpi-desync-split-pos=1,midsld
--dpi-desync-repeats=2
#Yv13
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=fake,multidisorder
--dpi-desync-split-seqovl=681
--dpi-desync-split-pos=1
--dpi-desync-fooling=badseq
--dpi-desync-badseq-increment=10000000
--dpi-desync-repeats=2
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
--dpi-desync-fake-tls-mod=rnd,dupsid,sni=fonts.google.com
#Yv14
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=fake,multidisorder
--dpi-desync-split-pos=10,midsld
--dpi-desync-fake-tls=0x00000000
--dpi-desync-fake-tls=0x0F0F0F0F
--dpi-desync-fake-tls=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
--dpi-desync-fake-tls-mod=rnd,dupsid,sni=fonts.google.com
--dpi-desync-split-seqovl=336
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
--dpi-desync-fooling=badseq
#Yv15
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=fake,multisplit
--dpi-desync-split-pos=2,sld
--dpi-desync-fake-tls=0x0F0F0F0F
--dpi-desync-fake-tls=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
--dpi-desync-fake-tls-mod=rnd,dupsid,sni=ggpht.com
--dpi-desync-split-seqovl=2108
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
--dpi-desync-fooling=badsum,badseq
#Yv16
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=multisplit
--dpi-desync-split-pos=1,sniext+1
--dpi-desync-split-seqovl=1
--dpi-desync-fooling=badsum,badseq
--dpi-desync-badseq-increment=0
#Yv17
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=fakeddisorder
--dpi-desync-fooling=md5sig
--dup=1
--dup-cutoff=n2
--dup-fooling=md5sig
--dpi-desync-split-pos=method+2
#Yv18
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--ip-id=zero
--dpi-desync=fake,hostfakesplit
--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com
--dpi-desync-hostfakesplit-mod=host=www.google.com,altorder=1
--dpi-desync-fooling=ts
#Yv19
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=fake,multisplit
--dpi-desync-fake-tls=0x00000000
--dpi-desync-fake-tls=!
--dpi-desync-split-pos=1,midsld
--dpi-desync-repeats=2
--dpi-desync-fooling=badseq
--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com
#Yv20
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--ip-id=zero
--dpi-desync=fake,fakedsplit
--dpi-desync-repeats=6
--dpi-desync-fooling=ts
--dpi-desync-fakedsplit-pattern=0x00
--dpi-desync-fake-tls=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
#Yv21
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--ip-id=zero
--dpi-desync=fake,multisplit
--dpi-desync-split-seqovl=681
--dpi-desync-split-pos=1
--dpi-desync-fooling=ts
--dpi-desync-repeats=8
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
--dpi-desync-fake-tls=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
#Yv22
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=split2
--dpi-desync-split-pos=1
--dpi-desync-split-seqovl=681
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/stun.bin
#Yv23
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=fake,fakeddisorder
--dpi-desync-split-pos=1
--dpi-desync-fake-tls=/opt/zapret/files/fake/stun.bin
--dpi-desync-fake-tls-mod=none
--dpi-desync-fakedsplit-pattern=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin
--dpi-desync-fooling=badseq,badsum
--dpi-desync-badseq-increment=0
#Yv24
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=fake,multisplit
--dpi-desync-split-seqovl=654
--dpi-desync-split-pos=1
--dpi-desync-fooling=badseq,badsum
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/stun.bin
--dpi-desync-fake-tls=/opt/zapret/files/fake/stun.bin
--dpi-desync-badseq-increment=0
#Yv25
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=hostfakesplit
--dpi-desync-fooling=badseq,badsum
--dpi-desync-hostfakesplit-mod=host=google.com
--dpi-desync-badseq-increment=0
#Yv26
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=multidisorder
--dpi-desync-split-pos=1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1
#Yv27
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=multidisorder
--dpi-desync-split-pos=1,2,3,5,105,host+5,sld-1,endsld-5,endsld
--dpi-desync-fooling=badsum
#Yv28
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=fake,multidisorder
--dpi-desync-split-seqovl=midsld-4
--dpi-desync-split-pos=2,midsld+3,sniext+2,endhost-2,midsld-3,host+1,-10
--dpi-desync-fooling=ts
--dpi-desync-repeats=23
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/tls_clienthello_www_sferum_ru.bin
--dpi-desync-fake-tls=/opt/zapret/files/fake/stun2.bin
--dpi-desync-fake-tls=/opt/zapret/files/fake/tls_clienthello_www_sferum_ru.bin
--dpi-desync-fake-tls=/opt/zapret/files/fake/stun.bin
--dpi-desync-fake-http=/opt/zapret/files/fake/tls_clienthello_max_ru.bin
#Yv29
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=hostfakesplit
--dpi-desync-fooling=ts
--dpi-desync-hostfakesplit-mod=host=www.google.com
--dpi-desync-hostfakesplit-midhost=midsld+1
#Yv30
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=hostfakesplit
--dpi-desync-fooling=ts
--dpi-desync-hostfakesplit-mod=host=www.google.com
--dpi-desync-hostfakesplit-midhost=sld+1
#Yv31
--filter-tcp=443
--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt
--dpi-desync=fake,multisplit
--dpi-desync-split-seqovl=717
--dpi-desync-split-pos=sld,sld+3,endhost-1
--dpi-desync-fooling=ts
--dpi-desync-repeats=8
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/tls_clienthello_www_google_com_2.bin
--dpi-desync-fake-tls=/opt/zapret/files/fake/tls_clienthello_www_google_com_2.bin
#Yv32
--filter-tcp=443
--hostlist-exclude=/opt/zapret/ipset/zapret-hosts-user-exclude.txt
--dpi-desync=hostfakesplit
--dpi-desync-hostfakesplit-mod=host=ozon.ru
--dpi-desync-repeats=4
--dpi-desync-fooling=ts,md5sig
--dpi-desync-badseq-increment=0
#Gv1
--filter-udp=88,1024-2407,2409-4499,4502-19293,19345-49999,50101-65535
--dpi-desync=fake
--dpi-desync-cutoff=d2
--dpi-desync-any-protocol=1
--dpi-desync-fake-unknown-udp=/opt/zapret/files/fake/stun.bin
--new
--filter-tcp=2099,2802,2302,2502,3478-3480,3724,6000-8000,8085,8090,8100,8903,8904,25565,27015-27030,27036-27037,35500-35600,50001,60442
--dpi-desync-any-protocol=1
--dpi-desync-cutoff=n5
--dpi-desync=multisplit
--dpi-desync-split-seqovl=582
--dpi-desync-split-pos=1
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/stun.bin
#Gv2
--filter-udp=88,1024-2407,2409-4499,4502-19293,19345-49999,50101-65535
--dpi-desync=fake
--dpi-desync-repeats=10
--dpi-desync-any-protocol=1
--dpi-desync-fake-unknown-udp=/opt/zapret/files/fake/stun.bin
--dpi-desync-cutoff=n2
--new
--filter-tcp=2099,2802,2302,2502,3478-3480,3724,6000-8000,8085,8090,8100,8903,8904,25565,27015-27030,27036-27037,35500-35600,50001,60442
--dpi-desync-any-protocol=1
--dpi-desync-cutoff=n5
--dpi-desync=multisplit
--dpi-desync-split-seqovl=582
--dpi-desync-split-pos=1
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/stun.bin
#Gv3
--filter-udp=88,1024-2407,2409-4499,4502-19293,19345-49999,50101-65535
--dpi-desync=fake
--dpi-desync-repeats=10
--dpi-desync-any-protocol=1
--dpi-desync-fake-unknown-udp=/opt/zapret/files/fake/stun.bin
--dpi-desync-cutoff=n3
--new
--filter-tcp=2099,2802,2302,2502,3478-3480,3724,6000-8000,8085,8090,8100,8903,8904,25565,27015-27030,27036-27037,35500-35600,50001,60442
--dpi-desync-any-protocol=1
--dpi-desync-cutoff=n5
--dpi-desync=multisplit
--dpi-desync-split-seqovl=582
--dpi-desync-split-pos=1
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/stun.bin
#Gv4
--filter-udp=88,1024-2407,2409-4499,4502-19293,19345-49999,50101-65535
--dpi-desync=fake
--dpi-desync-repeats=10
--dpi-desync-any-protocol=1
--dpi-desync-fake-unknown-udp=/opt/zapret/files/fake/stun.bin
--dpi-desync-cutoff=n4
--new
--filter-tcp=2099,2802,2302,2502,3478-3480,3724,6000-8000,8085,8090,8100,8903,8904,25565,27015-27030,27036-27037,35500-35600,50001,60442
--dpi-desync-any-protocol=1
--dpi-desync-cutoff=n5
--dpi-desync=multisplit
--dpi-desync-split-seqovl=582
--dpi-desync-split-pos=1
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/stun.bin
`;
const EMBEDDED_CONFIG = {
  "root": "/",
  "connect_timeout": 4,
  "request_timeout": 10,
  "settle_seconds": 2,
  "max_file_bytes": 2097152,
  "max_domains": 50000,
  "max_strategies": 256,
  "max_urls": 64,
  "hostlist_urls": {
    "exclude": "https://raw.githubusercontent.com/StressOzz/Zapret-Manager/main/zapret-hosts-user-exclude.txt"
  },
  "updater": {
    "repo": "swxfe/just-zapret-manager",
    "branch": "main",
    "path": "dist/just-zapret-manager.sh"
  }
};
const EMBEDDED_DATA = {};
EMBEDDED_DATA["sources.json"] = `{
  "manager_repo": "StressOzz/Zapret-Manager",
  "flowseal_repo": "Flowseal/zapret-discord-youtube",
  "installer_repo": "remittor/zapret-openwrt",
  "branch": "main",
  "tcp_ports": "2099,2802,2302,2502,3478-3480,3724,6000-8000,8085,8090,8100,8903,8904,25565,27015-27030,27036-27037,35500-35600,50001,60442",
  "udp_ports": "88,1024-2407,2409-4499,4502-19293,19345-49999,50101-65535",
  "fake_aliases": {
    "ACTIVE_DISCORD_UDP.bin": "quic_initial_steamcommunity_com.bin",
    "ACTIVE_GAME_UDP.bin": "quic_initial_4pda_to.bin",
    "tls_clienthello_4pda_to.bin": "4pda.bin",
    "tls_clienthello_max_ru.bin": "tls_clienthello_www_onetrust_com.bin"
  }
}
`;
EMBEDDED_DATA["network.json"] = `{
  "family": "inet",
  "table": "zapret",
  "chain": "postrouting_hook",
  "mark": "0x40000000"
}
`;
EMBEDDED_DATA["google.txt"] = `youtube.com
youtu.be
googlevideo.com
ytimg.com
ggpht.com
youtubei.googleapis.com
youtubei.youtube.com
gvt1.com
gvt2.com
googleplay.com
play.google.com
play.googleapis.com
googleusercontent.com
`;
EMBEDDED_DATA["exclude.txt"] = `skytunnel.pw
ru
by
рф
su
xn--p1ai
xn--p1acf
xn--80aswg
xn--d1acj3b
xn--80adxhks
xn--80asehdb
#################################### Разное
z.ai
hf.co
box.ca
2ip.io
uc.zone
msi.com
qwen.ai
iiko.it
okko.tv
ripe.net
ktalk.ru
avito.st
habr.com
vibio.tv
ali.click
nexon.com
tenor.com
boosty.to
ottai.com
ufanet.tv
apple.com
gudsen.vip
whatbox.ca
trovo.live
beeline.tv
ubuntu.com
xsolla.com
ip-api.com
yandex.com
yandex.org
yandex.net
chatglm.cn
gudsen.vip
pantum.com
gstatic.com
lichess.org
premier.one
teclast.com
wws-gs2.com
dropbox.com
genesis.com
carcade.com
midnight.im
easy4ip.com
senkuro.com
ibyteimg.com
duolingo.com
duolingo.cn
map-care.com
gravatar.com
battleye.com
opencity.pro
ipstream.one
godville.net
voidboost.cc
hcaptcha.com
gigabyte.com
bambulab.com
skillbox.pro
tarantool.io
kalay.net.cn
fanatical.com
mchose.com.cn
voidboost.one
kaspersky.com
canonical.com
mediafire.com
huggingface.co
mozaracing.com
vivoglobal.com
dolynkcloud.com
libreoffice.org
payguide.online
wanttopay.cloud
easy4ipcloud.com
feralhosting.com
moondroplab.tech
iotcplatform.com
dahuasecurity.com
rockstargames.com
docs.altlinux.org
battleye.b-cdn.net
download.nvidia.com
tiktoklinksafety.com
documentfoundation.org
marketplace.visualstudio.com
supporter-files.nexus-cdn.com
#################################### VK
vk.cc
vk.me
vk.com
my.com
mvk.com
vk.link
vk.team
vkgo.app
skbx.pro
youla.io
nyphy.io
mycdn.me
mradx.net
vk-cdn.me
vk.design
vk-cdn.net
vk.company
vklive.app
vkuser.net
vknext.net
bizmrg.com
userapi.com
vk-apps.com
vkcache.com
vkclips.app
vk-portal.net
vkuserlive.net
vkmessenger.app
vkmessenger.com
vkuseraudio.com
vkuseraudio.net
vkuservideo.com
vkuservideo.net
#################################### Epicgames
easy.ac
fab.com
quixel.se
quixel.com
eac-cdn.com
paragon.com
spyjinx.com
3lateral.com
fortnite.com
epicgames.com
epicgames.dev
hyprsense.com
sketchfab.com
artstation.com
roborecall.com
twinmotion.com
cubicmotion.com
playparagon.com
realityscan.com
epicgamescdn.com
radgametools.com
unrealengine.com
easyanticheat.net
shadowcomplex.com
battlebreakers.com
capturingreality.com
unrealtournament.com
#################################### Steam
s.team
steam.tv
dota2.com
valve.net
clngaa.com
qtlglb.com
comcast.net
steamcdn.com
steamcdn.net
steamstat.us
valvecdn.com
queniuqe.com
steam-api.com
steamchat.com
steamdeck.com
edgesuite.net
steam-chat.com
steamgames.com
steamgames.net
underlords.com
steamserver.net
steamstatic.com
slingshot.co.nz
playartifact.com
steam.cdn.on.net
steamcontent.com
steampowered.com
valvecontent.com
valvesoftware.com
valvesoftware.net
steambroadcast.com
steamcommunity.com
counter-strike.net
steamusercontent.com
gstore.val.manlaxy.com
steam.cdn.orcon.net.nz
steamdeckusercontent.com
#################################### OpenWRT
gitlab.io
github.io
github.com
openwrt.org
lede-project.org
githubusercontent.com
__JZM_JZM_UCODE_1__
)
export JZM_UCODE_1

JZM_UCODE_2=$(cat <<'__JZM_JZM_UCODE_2__'
#################################### UbisoftConnect
ubi.com
uplay.com
ubisoft.com
rainbow6.com
ubisoftconnect.com
#################################### Aliexpress
ae.com
ae-rus.net
alicdn.com
aestatic.net
aliexpress.us
aliexpress.com
aliexpress-media.com
#################################### PSN
scea.com
np.scea.com
ps5update.com
psdownload.com
playstation.net
playstation.com
account.sony.com
psremoteplay.com
playstationcloud.com
sonyentertainmentnetwork.com
#################################### Twitch
twitch.tv
ttvnw.net
jtvnw.net
twitchcdn.net
ext-twitch.tv
twitchsvc.net
live-video.net
twitch.a2z.com
twitch-shadow.net
twitchcdn-shadow.net
#################################### Valorant
pvp.net
vivox.com
sd-rtn.com
adjust.com
riotcdn.net
adobess.com
valorant.com
myqcloud.com
riotgames.com
playvalorant.com
#################################### TikTok
musical.ly
tiktok.com
tiktokv.eu
tiktokv.us
tiktokw.eu
tiktokw.us
muscdn.com
tiktokd.net
tiktokd.org
tiktokv.com
tiktokcdn.com
ibytedtos.com
ttwstatic.com
tik-tokapi.com
tiktok-row.net
tiktokminis.us
byteoversea.com
tiktok-minis.com
tiktokcdn-eu.com
tiktokcdn-us.com
tiktokeu-cdn.com
tiktokrow-cdn.com
tiktokglobalshopv.com
#################################### Hoyoverse
hoyo.link
hoyolab.com
yuanshen.com
hoyoverse.com
genshinimpact.com
honkaiimpact3.com
zenlesszonezero.com
#################################### Xiaomi
mi.com
miui.com
wali.com
c.mi.com
mgslb.com
mifile.cn
xiaomi.cn
mipay.com
youpin.cn
zmifi.com
70mai.com
mi-idc.com
mi-img.com
mijia.tech
mitvos.com
miwifi.com
xiaomi.com
xiaomi.net
duokan.com
saxyit.com
mi-fan.com
mihome.com
xiaomisa.cn
migames.com
miaibox.com
mi-home.com
xiaomicp.com
xiaomidns.cn
xiaomiev.com
xiaomiinc.cn
xiaominr.com
xiaomisa.com
xiaomisa.net
xiaomisa.org
roborock.com
mi-robot.com
yeelight.com
miot-spec.cn
xiaomidns.com
xiaomidns.net
xiaomiinc.com
xiaomiinc.net
duokanbox.com
youpin.com.cn
miot-spec.org
miot-spec.com
xiaomiwear.com
xiaomimimo.com
xiaomiprint.com
xiaomidns.com.cn
xiaomiinc.com.cn
xiaomimobile.com
xiaomixiaoai.com
xiaomiyoupin.com
xiaoaiassist.com
xiaomi-mijia.com
xiaomifactory.com
airstarfinance.net
#################################### Picooc
picoocru.com
picooc-g.com
picooc-int.com
#################################### Huawei
hc-cdn.cn
huawei.com
hc-cdn.com
huawei.net
hicloud.com
dbankcdn.com
dbankcloud.cn
dbankcloud.com
huaweicloud.com
huaweistatic.com
hwclouds-dns.com
hwclouds-dns.net
myhuaweicloud.cn
myhuaweicloud.com
huaweicloud-dns.cn
huaweicloud-dns.com
huaweicloud-dns.org
#################################### Delta Force
gtimg.com
volces.com
wetest.net
tencent.com
vasdgame.co
onezapp.com
intlgame.com
vasdgame.com
gcloudcs.com
fleetlogd.com
dgameglobal.com
tdatamaster.com
tencent-cloud.com
singaporepaya.com
playdeltaforce.com
quovadisglobal.com
jupiterlauncher.com
anticheatexpert.com
#################################### Microsoft
sfx.ms
msn.com
1drv.ms
live.com
lync.com
live.net
xbox.com
bing.com
skype.com
microsoft
fabric.io
msauth.net
office.net
office.com
msocdn.com
mojang.com
windows.net
msftauth.net
onedrive.com
microsoft.com
office365.com
sharepoint.com
skypeassets.com
s-microsoft.com
windowsupdate.com
microsoft-tst.com
microsoftonline.com
microsoftonline-p.com
minecraftservices.com
#################################### Xbox
xbx.lv
xbox.co
xbox.eu
xbox.org
xboxab.com
xbox360.co
xbox360.eu
xboxone.co
xboxone.eu
xboxnow.com
xboxera.com
xbox360.com
xbox360.org
xboxlive.cn
xboxone.com
gamepass.com
xboxlive.com
minecraft.net
xboxevents.com
orithegame.com
xboxrewards.com
xboxstudios.com
xboxservices.com
xboxliveauth.com
msauthimages.net
xboxgamepass.com
tellmewhygame.com
msftauthimages.net
xboxusercontent.com
msftconnecttest.com
xboxgamestudios.com
xboxplayanywhere.com
renovacionxboxlive.com
microsoftcasualgames.com
#################################### Arknights: Endfield
skport.com
hg-cdn.com
helpshift.com
gryphline.com
#################################### Samsung
sbixby.com
secb2b.com
samsung.com
bixbyllm.com
samsungdm.com
ospserver.net
samsunggsl.com
samsungosp.com
samsungqbe.com
samsungapps.com
samsungknox.com
samsungcloud.com
samsunghealth.com
samsungmobile.com
samsung-sm-ds.com
samsungcloudplatform.com
samsungcloudsolution.com
#################################### Tuya
tuya.com
iot334.com
tuyaeu.com
lifeaiot.com
tuyaedge.com
tuyacloud.com
smart-life.com
smartlifeconnect.com
#################################### TLC
tcl.com
tcljd.com
tclhome.com
tclclouds.com
#################################### Call Of Duty
azure.com
azureedge.net
demonware.net
callofduty.com
activision.com
cloudfront.net
#################################### Amazon
amazon.dev
amazon.com
amazonaws.com
amazontrust.com
media-amazon.com
#################################### Akamai
akamai.net
akamaihd.net
akamaized.net
akamaiedge.net
#################################### Reddit
redd.it
reddit.com
redditstatic.com
redditspace.com
redditmedia.com
####################################  LG WebOs
lge.com
lgeapi.com
lgtvsdp.com
lgappstv.com
nextlgsdp.com
lgtvcommon.com
#################################### Сursor
cursor.sh
cursor.com
cursorapi.com
todesktop.com
cursor-cdn.com
#################################### Warface
qq.com
qcloud.com
#################################### EA Games
ea.com
swtor.com
origin.com
tnt-ea.com
easports.com
eamobile.com
#################################### IP Camera
av380.net
hiseese.com
icloseli.com
ucloudcam.com
#################################### The Finals
codefusion.technology
ac-upd.codefusion.technology
ac-trg.codefusion.technology
ac-rep.codefusion.technology
ac-knock.codefusion.technology
ac-prp-ap.codefusion.technology
ac-survey.codefusion.technology
ac-fallback.codefusion.technology
ac-fileshare.codefusion.technology
#################################### Wordpress
wp.com
9to5mac.com
wptavern.com
wordpress.com
9to5google.com
techcrunch.com
#################################### PUBG
pubg.com
pubgno1.cn
pubgtool.com
kraftonde.com
pubghelper.com
pubg1.battleye.com
playbattlegrounds.com
#################################### Tumblr
tmblr.com
tumblr.com
#################################### Postman
postman.com
getpostman.com
postmanapp.com
#################################### Radmin
radmin.com
famatech.com
radmin-vpn.com
#################################### Black Desert Online
wellbia.com
bdocodex.com
pearl-bdo.com
pearlabyss.com
playblackdesert.com
#################################### bip.com
bip.ai
bip.com
netmera-web.com
#################################### kino.pub
cdntogo.net
cdn2cdn.com
cdn2site.com
nearcache.net
staticpop.net
digital-cdn.net
#################################### Dreame
dreame.tech
dreametech.com
dreamehome.com
dreame-technology.cn
dreame-technology.com
#################################### Arena Breakout Infinite
li.com
netease.com
tencent.com
igamecj.com
gcloudcs.com
intlgame.com
proximabeta.com
levelinfinite.com
arenabreakout.com
arenabreakoutinfinite.com
#################################### Aniimo
funplus.com
guardease.com
kingsgroupgames.com
#################################### tp-link
tp-link.com
tplinkra.com
tplinkap.net
tplinknbu.com
tplinkdns.com
tplinkwifi.net
tplinkcloud.com
tplinklogin.net
tplinkrepeater.net
#################################### Nintendo
nintendo.com
nintendo.net
nintendo.co.jp
nintendo.com.au
nintendo.com.uk
nintendo.com.hk
nintendo.com.tw
nintendo.com.cn
nintendo-europe.com
#################################### Хmeye
xmeye.net
xiongmaitech.com
#################################### Pico
picoxr.com
picovr.com
#################################### Apple
me.com
asto.re
itun.es
mac.com
apple.co
apple.ru
apple.com
appsto.re
apple.news
shazam.com
itunes.com
icloud.com
akadns.net
appleid.com
itunesu.com
aaplimg.com
edgekey.net
mzstatic.com
apple-dns.net
apple-dns.com
cdn-apple.com
edgesuite.net
applemusic.com
apple-mapkit.com
apple-studies.com
apple-cloudkit.com
services-apple.net
icloud-content.com
icloud-sandbox.com
apple-livephotoskit.com
axm-usercontent-apple.com
#################################### Pinterest
pinimg.com
pinimg.map.fastly.net
####################################
`;
EMBEDDED_DATA["urls.txt"] = `# Замените/дополните адресами, которые требуется проверить на вашем подключении.
https://www.youtube.com/
# Диагностика доступности инфраструктуры Googlevideo (не замер скорости видео).
https://redirector.googlevideo.com/report_mapping
https://discord.com/
`;
EMBEDDED_DATA['strategies.txt'] = EMBEDDED_STRATEGIES;
const EMBEDDED_HEADER = "#!/bin/sh\n# JZM_VERSION=0.1.2\n# JZM_FORMAT=2\n# Generated from src/. This file contains readable shell and ucode source.\nset -eu\nJZM_PID=$$\nexport JZM_PID\ncommand -v ucode >/dev/null 2>&1 || {\n    printf '%s\\n' 'jzm: требуется ucode и пакет ucode-mod-fs' >&2\n    exit 127\n}\n[ \"${JZM_MODE:-}\" = command ] || [ \"$#\" -eq 0 ] || {\n    printf '%s\\n' 'Запустите менеджер без аргументов: jzm' >&2\n    exit 2\n}\n";
const EMBEDDED_FOOTER = "# Source is compiled in memory. Separate environment values stay below Linux's\n# per-argument limit; stdin remains available to the terminal menu and blockcheck.\n# This value is ucode source passed as one interpreter argument.\n# shellcheck disable=SC2089\nJZM_BOOTSTRAP='let source = \"\"; for (let i = 1; i <= +getenv(\"JZM_PARTS\"); i++) source += getenv(\"JZM_UCODE_\" + i) + \"\\n\"; loadstring(source, { strict_declarations: true })();'\nZM_HOME=${ZM_HOME:-/}\n# shellcheck disable=SC2090\nexport JZM_BOOTSTRAP ZM_HOME\nexec ucode -S -e \"$JZM_BOOTSTRAP\" -- \"$@\"\n";

// ---- src/lib/resources.uc ----

const VERSION = '0.1.2';

// The bundler replaces these accessors with references to generated constants.
function embedded_data() { return EMBEDDED_DATA; };
function embedded_config() { return EMBEDDED_CONFIG; };
function embedded_header() { return EMBEDDED_HEADER; };
function embedded_footer() { return EMBEDDED_FOOTER; };

function resource(home, name) {
    let data = embedded_data();
    if (data != null) {
        if (!exists(data, name)) die('неизвестный встроенный ресурс: ' + name);
        return data[name];
    }
    let body = fs.readfile(home + '/data/' + name);
    if (body == null) die('не найден ресурс: ' + name);
    return body;
};

// ---- src/lib/common.uc ----

function check(condition, message) {
    if (!condition) die(message);
};

function tempdir() {
    // The fs.mkdtemp API is absent from ucode shipped with OpenWrt 24.10.
    // This fixed command has no caller-provided arguments to interpolate.
    let proc = fs.popen('mktemp -d /tmp/zm-io-XXXXXX', 'r');
    check(proc != null, 'невозможно запустить mktemp');
    let path = trim(proc.read('all') || '');
    let rc = proc.close();
    check(rc == 0 && match(path, /^\/tmp\/zm-io-[A-Za-z0-9]+$/),
          'невозможно создать временный каталог');
    return path;
};

function read(path, limit) {
    let st = fs.stat(path);
    check(st != null && st.type == 'file', 'не найден обычный файл: ' + path);
    check(st.size <= limit, 'слишком большой файл: ' + path);
    let value = fs.readfile(path, limit + 1);
    check(value != null && length(value) <= limit, 'ошибка чтения: ' + path);
    check(index(value, '\x00') == -1, 'NUL в текстовом файле: ' + path);
    return value;
};

function backend_command(ctx, action, args) {
    let cmd = getenv('JZM_BACKEND') ? ['/bin/sh', '-c', getenv('JZM_BACKEND'), 'jzm-backend', action, ctx.root, ctx.profile] :
        ['/bin/sh', ctx.home + '/src/shell/backend.sh', action, ctx.root, ctx.profile];
    for (let arg in (args || [])) push(cmd, '' + arg);
    return cmd;
}

function backend(ctx, action, args) {
    return system(backend_command(ctx, action, args));
};

function run(ctx, action, args) {
    let rc = backend(ctx, action, args);
    check(rc == 0, sprintf('%s: код завершения %d', action, rc));
};

function output(ctx, action, args) {
    let stream = { 'config-get': 'config-read', 'config-get-optional': 'config-read-optional',
                   'hosts-read': 'hosts-read-stdout' }[action];
    if (stream != null) {
        let cmd = backend_command(ctx, stream, args);
        let quoted = map(cmd, (arg) => "'" + replace(arg, /'/g, "'\\''") + "'");
        let proc = fs.popen(join(' ', quoted), 'r');
        check(proc != null, 'не удалось запустить ' + action);
        let value = '', oversized = false;
        // Drain an oversized result before close, keeping memory bounded and avoiding a full pipe deadlock.
        for (let chunk = proc.read(4096); chunk != null && length(chunk); chunk = proc.read(4096)) {
            if (!oversized) value += chunk;
            if (length(value) > ctx.max_file_bytes) oversized = true;
        }
        let rc = proc.close();
        check(rc == 0, sprintf('%s: код завершения %d', action, rc));
        check(!oversized, 'слишком большой результат ' + action);
        check(index(value, '\x00') == -1, 'NUL в текстовом результате: ' + action);
        return value;
    }
    // Capture through a private directory; arguments never pass through a shell parser.
    let dir = tempdir();
    let value;
    try {
        run(ctx, action, [dir + '/result', ...(args || [])]);
        value = read(dir + '/result', ctx.max_file_bytes);
    }
    catch (e) {
        fs.unlink(dir + '/result');
        fs.rmdir(dir);
        die(e.message);
    }
    fs.unlink(dir + '/result');
    fs.rmdir(dir);
    return value;
};

function write(path, text) {
    check(fs.writefile(path, text) == length(text), 'ошибка записи: ' + path);
};

function send(ctx, action, args, text) {
    let dir = tempdir();
    try {
        write(dir + '/input', text);
        run(ctx, action, [dir + '/input', ...(args || [])]);
    }
    catch (e) {
        fs.unlink(dir + '/input');
        fs.rmdir(dir);
        die(e.message);
    }
    fs.unlink(dir + '/input');
    fs.rmdir(dir);
};

function invoke(ctx, args) {
    let cmd = getenv('JZM_BOOTSTRAP') ?
        ['/bin/sh', '-c', 'JZM_MODE=command exec ucode -S -e "$JZM_BOOTSTRAP" -- "$@"', 'jzm-command'] :
        ['/bin/sh', '-c', 'JZM_MODE=command exec /bin/sh "$@"', 'jzm-command', ctx.home + '/src/launcher.sh'];
    return system([...cmd, ...(fs.stat(ctx.file) ? ['--config', ctx.file] : []), ...args]);
};

function target_text(ctx, file) {
    return file == '@default' ? resource(ctx.home, 'urls.txt') : read(file, ctx.max_file_bytes);
};

// ---- src/lib/settings.uc ----

function settings(home, file) {
    file = file || (fs.stat('/etc/zapret-manager/manager-config.json') ? '/etc/zapret-manager/manager-config.json' : null);
    let c = file ? json(read(file, 65536)) : (embedded_config() || json(read(home + '/data/manager.json', 65536)));
    c = json(sprintf('%J', c));
    check(type(c) == 'object', 'manager.json: ожидается объект');
    let allowed = ['root', 'updater', 'connect_timeout', 'request_timeout',
        'settle_seconds', 'max_file_bytes', 'max_domains', 'max_strategies',
        'max_urls', 'hostlist_urls', 'sources'];
    for (let key in keys(c))
        check(index(allowed, key) != -1, 'неизвестная настройка: ' + key);
    c.profile = 'zapret';
    check(type(c.root) == 'string' && match(c.root, /^\/([A-Za-z0-9_. -]+\/)*[A-Za-z0-9_. -]*$/) &&
          !match(c.root, /(^|\/)\.\.?(\/|$)/), 'root: нужен абсолютный путь без . и ..');
    c.root = c.root == '/' ? '' : replace(c.root, /\/$/, '');
    for (let key in ['connect_timeout', 'request_timeout', 'settle_seconds',
                     'max_file_bytes', 'max_domains', 'max_strategies', 'max_urls']) {
        check(type(c[key]) == 'int' && c[key] >= (key == 'settle_seconds' ? 0 : 1) &&
              c[key] <= (key == 'max_file_bytes' ? 8388608 : 50000), 'некорректная настройка: ' + key);
    }
    check(c.connect_timeout <= c.request_timeout && c.request_timeout <= 300 &&
          c.settle_seconds <= 60 && c.max_strategies <= 1024 && c.max_urls <= 256,
          'таймауты или лимиты превышены');
    check(type(c.hostlist_urls) == 'object', 'hostlist_urls: ожидается объект');
    for (let key, url in c.hostlist_urls) {
        check(index(['user', 'exclude', 'google'], key) != -1, 'неизвестный список: ' + key);
        check(type(url) == 'string' && match(url, /^https:\/\/[^[:space:]]+$/), 'URL списка должен быть HTTPS');
    }
    c.home = home;
    c.file = file || c.root + '/etc/zapret-manager/manager-config.json';
    c.config = c.root + '/etc/config/' + c.profile;
    c.base = c.root + '/opt/' + c.profile;
    c.state = c.root + '/etc/zapret-manager';
    if (c.sources == null) c.sources = json(resource(home, 'sources.json'));
    check(type(c.sources) == 'object', 'неверные настройки источников');
    for (let key in ['manager_repo', 'flowseal_repo', 'installer_repo'])
        check(type(c.sources[key]) == 'string' && match(c.sources[key], /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/), 'неверный источник: ' + key);
    check(match(c.sources.branch, /^[A-Za-z0-9_.-]+$/), 'неверная ветка источника');
    check(type(c.sources.fake_aliases) == 'object', 'неверная таблица fake-файлов');
    if (c.updater == null) c.updater = { repo: '', branch: 'main', path: 'dist/just-zapret-manager.sh' };
    check(type(c.updater) == 'object' && type(c.updater.repo) == 'string' &&
        (c.updater.repo == '' || match(c.updater.repo, /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/)), 'неверный репозиторий обновлений');
    check(match(c.updater.branch, /^[A-Za-z0-9_.-]+$/) &&
        match(c.updater.path, /^[A-Za-z0-9_.\/-]+$/) && !match(c.updater.path, /(^|\/)\.\.?(\/|$)/), 'неверный путь обновлений');
    return c;
};

// ---- src/lib/strategies.uc ----

let general_cleanup = null, general_edges = null;

function strategy_key(name) {
    if (lc(substr(name || '', 0, 7)) != 'general') return name;
    let separator = substr(name, 7, 1);
    if (length(separator) && index('_.-', separator) == -1) return name;
    if (general_cleanup == null) { general_cleanup = /[^a-z0-9]+/g; general_edges = /^_|_$/g; }
    return replace(replace(lc(name), general_cleanup, '_'), general_edges, '');
};

function strategy_group(name) {
    if (match(name || '', /^v[0-9]+$/)) return 'base';
    if (match(name || '', /^Yv[0-9]+$/)) return 'youtube';
    if (match(name || '', /^Dv[0-9]+$/)) return 'discord';
    if (match(name || '', /^Gv[0-9]+$/)) return 'games';
    return null;
};

function strategy_title(name) {
    let key = strategy_key(name);
    if (key == 'general') return 'general (базовый)';
    let alt = match(key || '', /^general_alt([0-9]+)(.*)$/);
    return alt ? 'general (ALT' + alt[1] + replace(alt[2], /_/g, ' ') + ')' : key;
};

function strategy_order(left, right) {
    let a = strategy_key(left.name), b = strategy_key(right.name);
    if (a == b) return 0;
    if (a == 'general') return -1;
    if (b == 'general') return 1;
    let x = match(a, /^([^0-9]*)([0-9]+)(.*)$/), y = match(b, /^([^0-9]*)([0-9]+)(.*)$/);
    if (x && y && x[1] == y[1] && +x[2] != +y[2]) return +x[2] < +y[2] ? -1 : 1;
    return a < b ? -1 : 1;
};

function profile_group(block) {
    if (index(block, '--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt') != -1) return 'youtube';
    if (index(block, '--hostlist-domains=discord.media') != -1) return 'discord';
    if (index(block, '--dpi-desync-any-protocol=1') != -1) return 'games';
    if (match(block, /^--filter-tcp=(80,)?443(\n|,)/)) return 'base';
    return null;
};

function validate_body(body) {
    check(length(body) > 0 && length(body) <= 32768, 'пустая или слишком большая стратегия');
    let lines = [], option_pattern = /^--[A-Za-z0-9][A-Za-z0-9_-]*(=[A-Za-z0-9_.,:\/+=@%{}!~-]+)?$/;
    for (let raw in split(body, '\n')) {
        let line = trim(raw);
        if (!length(line) || substr(line, 0, 1) == '#') continue;
        // Upstream expands NFQWS_OPT as shell words. Reject substitutions and quoting.
        check(match(line, option_pattern),
              'недопустимая строка стратегии: ' + line);
        push(lines, line);
    }
    check(length(lines) > 0 && lines[0] != '--new' && lines[-1] != '--new',
          'пустой блок стратегии');
    for (let i = 1; i < length(lines); i++)
        check(lines[i] != '--new' || lines[i - 1] != '--new', 'соседние --new');
    return join('\n', lines) + '\n';
};

function strategy_sections(body) {
    let sections = [], label = null, words = [];
    let marker_pattern = /^#([A-Za-z0-9][A-Za-z0-9_.-]*)$/, separators = /[[:space:]]+/;
    for (let raw in split(body || '', '\n')) {
        let line = trim(raw), marker = match(line, marker_pattern);
        if (marker && length(marker[1]) > 64) marker = null;
        if (marker) {
            if (label != null || length(words)) {
                // A delimiter immediately before the next heading joins presets.
                // All other --new tokens remain inside their original preset.
                let separated = words[-1] == '--new';
                if (separated) pop(words);
                push(sections, { label, body: length(words) ? join('\n', words) + '\n' : '', boundary_missing: !separated });
            }
            label = marker[1]; words = [];
            continue;
        }
        line = trim(split(line, '#')[0]);
        if (length(line)) for (let word in split(line, separators)) push(words, word);
    }
    if (label != null || length(words))
        push(sections, { label, body: length(words) ? join('\n', words) + '\n' : '', boundary_missing: false });
    return sections;
};

function preserve_body(body) {
    let sections = strategy_sections(body), result = [];
    check(length(sections), 'пустая стратегия');
    for (let section in sections) {
        check(!section.boundary_missing, 'между стратегиями требуется --new');
        let normalized = validate_body(section.body);
        push(result, (section.label != null ? '#' + section.label + '\n' : '') + normalized);
    }
    let value = join('--new\n', result);
    check(length(value) <= 32768, 'слишком большая стратегия с метками');
    return value;
};

function label_strategy(name, body) {
    check(type(name) == 'string' && length(name) <= 64 && match(name, /^[A-Za-z0-9][A-Za-z0-9_.-]*$/), 'неверное имя стратегии');
    return preserve_body('#' + strategy_key(name) + '\n' + validate_body(body));
};

function parse_catalog(ctx, text, wanted) {
    check(type(text) == 'string' && index(text, '\x00') == -1, 'неверный текст каталога');
    let sections = split('\n' + text, /\n[ \t\r]*#/), result = [], seen = {};
    let name_pattern = /^[A-Za-z0-9][A-Za-z0-9_.-]*$/;
    check(!length(trim(sections[0])), 'стрратегия без заголовка #имя');
    check(length(sections) > 1 && length(sections) - 1 <= ctx.max_strategies, 'лимит числа стратегий');
    // Native splitting visits only preset headers; inactive bodies need no interpreted line scan.
    for (let i = 1; i < length(sections); i++) {
        let section = sections[i], end = index(section, '\n');
        let name = trim(end == -1 ? section : substr(section, 0, end));
        check(length(name) <= 64 && match(name, name_pattern), 'неверное имя стратегии: ' + name);
__JZM_JZM_UCODE_2__
)
export JZM_UCODE_2

JZM_UCODE_3=$(cat <<'__JZM_JZM_UCODE_3__'
check(!seen[name], 'повтор стратегии: ' + name);
        seen[name] = true;
        if (wanted == null || index(wanted, strategy_key(name)) != -1)
            push(result, { name, body: validate_body(end == -1 ? '' : substr(section, end + 1)) });
    }
    return result;
};

function catalog(ctx, file, wanted) {
    let text = file ? read(file, ctx.max_file_bytes) : resource(ctx.home, 'strategies.txt');
    return parse_catalog(ctx, text, wanted);
};

function select_strategy(ctx, name, file) {
    let list = catalog(ctx, file, [strategy_key(name)]);
    let found = filter(list, (s) => s.name == name);
    check(length(found) == 1, 'стратегия не найдена: ' + name);
    return found[0];
};

function compose_bodies(bodies) {
    // nfqws selects the first matching profile: Google must precede broad TCP/443.
    let google = (body) => index(body, '--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt') != -1;
    return preserve_body(join('--new\n', [...filter(bodies, google), ...filter(bodies, (body) => !google(body))]));
};

function compose(ctx, names, file) {
    check(length(names) > 0, 'укажите имена стратегий');
    let seen = {};
    for (let name in names) { check(!seen[name], 'повтор стратегии: ' + name); seen[name] = true; }
    let list = catalog(ctx, file, map(names, strategy_key));
    return compose_bodies(map(names, (name) => {
        let found = filter(list, (s) => s.name == name);
        check(length(found) == 1, 'стратегия не найдена: ' + name);
        return label_strategy(name, found[0].body);
    }));
};

function replace_group(current, replacement, group) {
    check(index(['base', 'youtube', 'discord', 'games'], group) != -1, 'неизвестная группа стратегии');
    let keep = [];
    for (let section in strategy_sections(current)) {
        let family = strategy_group(section.label);
        if (family == group) continue;
        if (family != null) {
            push(keep, '#' + section.label + '\n' + validate_body(section.body));
            continue;
        }
        let blocks = [];
        for (let block in split(validate_body(section.body), '--new\n')) {
            let voice = index(block, '--filter-l7=discord,stun') != -1;
            if (profile_group(block) == group || (!length(replacement) && group == 'discord' && voice)) continue;
            push(blocks, block);
        }
        if (length(blocks)) push(keep, (section.label != null ? '#' + section.label + '\n' : '') + join('--new\n', blocks));
    }
    if (length(replacement)) {
        if (group == 'youtube') keep = [preserve_body(replacement), ...keep];
        else push(keep, preserve_body(replacement));
    }
    return length(keep) ? preserve_body(join('--new\n', keep)) : '';
};

function remove_flowseal(current) {
    let keep = filter(strategy_sections(current), (s) => !match(strategy_key(s.label) || '', /^general(_|$)/));
    return length(keep) ? preserve_body(join('--new\n', map(keep,
        (s) => (s.label != null ? '#' + s.label + '\n' : '') + s.body))) : '';
};

// ---- src/lib/domains.uc ----

function validate_list_snapshot(text, limit, max_bytes) {
    // Backups preserve upstream's IP/CIDR, suffixes, Unicode and comments verbatim.
    // This is data copied to a fixed list path, never shell source or CLI arguments.
    check(type(text) == 'string' && length(text) <= max_bytes, 'слишком большой список в резервной копии');
    check(index(text, '\x00') == -1 && !match(text, /[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]/),
        'управляющие байты в списке резервной копии');
    // Search bounded byte windows in native code instead of interpreting every byte.
    // This preserves the byte limit for UTF-8 and never allocates a list of lines.
    let count = 0, size = length(text), nonblank = /[^ \t\r]/;
    for (let offset = 0; offset < size;) {
        let window = substr(text, offset, 1025), end = index(window, '\n');
        check(end != -1 || length(window) <= 1024, 'слишком длинная строка списка резервной копии');
        let line = end == -1 ? window : substr(window, 0, end);
        if (match(line, nonblank)) count++;
        check(count <= limit, 'превышен лимит строк списка резервной копии');
        offset += end == -1 ? length(window) : end + 1;
    }
    return true;
};

function domains(text, limit) {
    let seen = {}, result = [], label_pattern = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/;
    for (let raw in split(text, '\n')) {
        let name = lc(trim(split(raw, '#')[0]));
        if (!length(name)) continue;
        check(length(name) <= 253 && index(name, '.') != -1, 'неверный домен: ' + name);
        for (let label in split(name, '.'))
            check(length(label) <= 63 && match(label, label_pattern), 'неверный домен: ' + name);
        if (!exists(seen, name)) {
            seen[name] = true;
            push(result, name);
        }
        check(length(result) <= limit, 'превышен лимит доменов');
    }
    return sort(result);
};

function urls(text, limit) {
    let result = [];
    for (let raw in split(text, '\n')) {
        let url = trim(raw);
        if (!length(url) || substr(url, 0, 1) == '#') continue;
        check(length(url) <= 2048, 'URL длиннее 2048 байт');
        check(match(url, /^https?:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?(\/[^[:space:]]*)?$/), 'неверный URL: ' + url);
        push(result, url);
        check(length(result) <= limit, 'превышен лимит URL');
    }
    check(length(result) > 0, 'список URL пуст');
    return result;
};

// ---- src/lib/devices.uc ----

function ipv4(value) {
    check(type(value) == 'string' && match(value, /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/), 'неверный IPv4 адрес');
    let octets = split(value, '.');
    for (let part in octets) check(+part <= 255, 'октет IPv4 вне диапазона');
    return join('.', map(octets, (part) => '' + (+part)));
};

function legacy_addresses(body) {
    body = trim(replace(body, /\\\r?\n/g, ' '));
    if (!length(body)) return [];
    let lines = split(body, '\n');
    if (length(lines) != 2) return null;
    let m = match(lines[0], /^EXCEPT_SRC='\{ ([0-9., ]+) \}'$/);
    if (!m || replace(trim(lines[1]), /[[:space:]]+/g, ' ') !=
        'nft insert rule inet zapret postrouting_hook index 0 ip saddr $EXCEPT_SRC meta mark set meta mark \\| 0x40000000') return null;
    let values = map(split(m[1], ','), (part) => ipv4(trim(part)));
    check(length(values) <= 256, 'слишком много старых исключений устройств');
    return values;
};

function legacy_exclusions(ctx) {
    let path = ctx.base + '/init.d/openwrt/custom.d/20-script.sh';
    return fs.stat(path) ? legacy_addresses(read(path, 16384)) : null;
};

function excluded(ctx) {
    let path = ctx.state + '/devices.txt', result = legacy_exclusions(ctx) || [];
    let body = fs.stat(path) ? read(path, 16384) : '';
    for (let line in split(body, '\n')) {
        line = trim(line);
        if (length(line)) {
            let ip = ipv4(line);
            if (index(result, ip) == -1) push(result, ip);
        }
    }
    check(length(result) <= 256, 'слишком много исключённых устройств');
    return result;
};

function device_list(ctx) {
    let items = {}, path = ctx.root + '/tmp/dhcp.leases';
    if (fs.stat(path)) {
        for (let line in split(read(path, ctx.max_file_bytes), '\n')) {
            let fields = split(trim(line), /[[:space:]]+/);
            if (length(fields) < 4) continue;
            try {
                let ip = ipv4(fields[2]);
                items[ip] = { ip, name: fields[3] == '*' ? 'устройство' : replace(fields[3], /[^A-Za-z0-9_.:-]/g, '_') };
            }
            catch (e) { /* Incomplete DHCP rows do not become firewall rules. */ }
        }
    }
    for (let ip in excluded(ctx)) if (!exists(items, ip)) items[ip] = { ip, name: 'вне DHCP / offline' };
    return map(sort(keys(items)), (ip) => items[ip]);
};

function exclusion_hook(ctx, addresses) {
    let cfg = json(resource(ctx.home, 'network.json'));
    for (let key in ['family', 'table', 'chain'])
        check(match(cfg[key], /^[A-Za-z_][A-Za-z0-9_]*$/), 'неверный параметр nft: ' + key);
    check(match(cfg.mark, /^0x[a-fA-F0-9]{1,8}$/), 'неверная метка nft');
    check(length(addresses) <= 256, 'слишком много исключений');
    addresses = map(addresses, (value) => ipv4(value));
    let rule = !length(addresses) ? '    exit 0\n' :
        '    jzm_chain=$(nft -a list chain ' + cfg.family + ' ' + cfg.table + ' ' + cfg.chain + ') || exit 1\n' +
        '    case "$jzm_chain" in *\'comment "jzm_devices"\'*) exit 0;; esac\n' +
        '    nft insert rule ' + cfg.family + ' ' + cfg.table + ' ' + cfg.chain +
        " index 0 ip saddr '{ " + join(', ', addresses) + " }' meta mark set meta mark \\| " + cfg.mark +
        ' comment \'"jzm_devices"\'\n';
    // custom_runner sources each file for daemon, firewall and flush callbacks.
    // Define the nft callback only; restore the caller's shell options after sourcing.
    return '#!/bin/sh\n# shellcheck disable=SC2329\njzm_exclusion_flags=$-\nset -eu\n' +
        'zapret_custom_firewall_nft() (\n    set -eu\n' + rule + ')\n' +
        'case "$jzm_exclusion_flags" in *e*) :;; *) set +e;; esac\n' +
        'case "$jzm_exclusion_flags" in *u*) :;; *) set +u;; esac\n' +
        'unset jzm_exclusion_flags\n';
};

// ---- src/lib/applied.uc ----

// Exact text keys keep manual edits visible; bound the cache to four 64 KiB inputs.
let digest_cache = [];

function normalize_options(body) {
    let words = [], separators = /[[:space:]]+/;
    for (let raw in split(body || '', '\n')) {
        let line = trim(split(raw, '#')[0]);
        if (length(line)) for (let word in split(line, separators)) push(words, word);
    }
    return length(words) ? join('\n', words) + '\n' : '';
};

function sha256_text(text) {
    check(type(text) == 'string' && length(text) <= 65536 && index(text, '\x00') == -1, 'неверные данные для SHA256');
    for (let entry in digest_cache) if (entry.text == text) return entry.digest;
    // Quote every byte, including user-supplied apostrophes; printf never interprets data as code.
    let quoted = "'" + replace(text, /'/g, "'\\''") + "'";
    check(length(quoted) < 100000, 'слишком большие данные для SHA256');
    let proc = fs.popen("printf '%s' " + quoted + ' | sha256sum', 'r');
    check(proc != null, 'не удалось запустить sha256sum');
    let reply = proc.read(256) || '', rc = proc.close();
    let digest = match(reply, /^([a-f0-9]+)[ \t]+[*]?-/);
    check(rc == 0 && digest && length(digest[1]) == 64, 'не удалось вычислить SHA256; нужна команда sha256sum');
    if (length(digest_cache) == 4) shift(digest_cache);
    push(digest_cache, { text, digest: digest[1] });
    return digest[1];
};

function strategy_hash(body) {
    return sha256_text(normalize_options(body));
};

function validate_applied(state) {
    check(type(state) == 'object' && type(state.name) == 'string' && length(state.name) > 0 &&
        length(state.name) <= 4096 && index(state.name, '\x00') == -1 && !match(state.name, /[\x01-\x1f\x7f]/) &&
        type(state.applied_hash) == 'string' && length(state.applied_hash) == 64 && match(state.applied_hash, /^[a-f0-9]+$/) &&
        type(state.applied_at) == 'int' && state.applied_at >= 0, 'повреждён state.json');
    if (state.sections != null) {
        let name_pattern = /^[A-Za-z0-9][A-Za-z0-9_.-]*$/;
        check(type(state.sections) == 'array' && length(state.sections) <= 1024, 'неверный состав state.json');
        for (let section in state.sections) {
            check(type(section) == 'object' && (section.name == null || (type(section.name) == 'string' &&
                length(section.name) <= 64 && match(section.name, name_pattern))) &&
                type(section.omit) == 'array' && length(section.omit) <= 5, 'неверная секция state.json');
            for (let group in section.omit) check(index(['base', 'youtube', 'discord', 'games', 'voice'], group) != -1,
                'неверная группа state.json');
        }
    }
    return state;
};

function read_applied(ctx) {
    let path = ctx.state + '/state.json';
    return fs.stat(path) ? validate_applied(json(read(path, 65536))) : null;
};

function applied_names(state) {
    if (state == null) return [];
    return state.sections != null ? map(state.sections, (s) => strategy_key(s.name)) :
        map(split(state.name, /[ \t]*\+[ \t]*/), (name) => strategy_key(name));
};

function reference_index(list) {
    let result = {};
    for (let item in list) {
        let name = strategy_key(item.name);
        if (result[name] == null) result[name] = normalize_options(item.body);
    }
    return result;
}

function applied_profile_kind(block) {
    return profile_group(block) || (index(block, '--filter-l7=discord,stun') != -1 ? 'voice' : null);
}

function create_applied(body, sections, list, applied_at) {
    let refs = reference_index(list), recipe = [], names = [];
    for (let section in sections) {
        let name = strategy_key(section.name), omit = [];
        if (name != null && refs[name] != null && match(name, /^general(_|$)/)) {
            let current = map(split(normalize_options(section.body), '--new\n'), applied_profile_kind);
            let original = map(split(refs[name], '--new\n'), applied_profile_kind);
            for (let group in ['base', 'youtube', 'discord', 'games', 'voice'])
                if (index(original, group) != -1 && index(current, group) == -1) push(omit, group);
        }
        push(recipe, { name, omit });
        push(names, name || 'кастомный блок');
    }
    let name = length(filter(recipe, (s) => s.name != null)) ? join(' + ', names) : 'кастомная';
    if (!length(normalize_options(body))) name = 'не выбрана';
    return validate_applied({ name, applied_hash: strategy_hash(body), applied_at, sections: recipe });
};

function applied_catalog_hash(state, list) {
    if (state == null) return null;
    validate_applied(state);
    let refs = reference_index(list), bodies = [];
    let recipe = state.sections != null ? state.sections : map(applied_names(state), (name) => ({ name, omit: [] }));
    for (let section in recipe) {
        let ref = refs[strategy_key(section.name)];
        if (section.name == null || ref == null) return null;
        let blocks = filter(split(ref, '--new\n'), (block) => index(section.omit, applied_profile_kind(block)) == -1);
        if (length(blocks)) push(bodies, join('--new\n', blocks));
    }
    return strategy_hash(join('--new\n', bodies));
};

function applied_status(current_hash, state, catalog_hash, empty) {
    if (empty) return 'не выбрана';
    if (state == null || catalog_hash == null) return 'кастомная';
    validate_applied(state);
    let changed = current_hash != state.applied_hash, update = state.applied_hash != catalog_hash;
    if (changed && update) return state.name + ' (изменена вами, есть обновление)';
    if (changed) return state.name + ' (изменена пользователем)';
    return state.name + (update ? ' (доступно обновление)' : '');
};

// ---- src/lib/status.uc ----

function parse_packages(body, format) {
    let result = {};
    for (let record in split(replace(body, /\r/g, '') + '\n\n', /\n\n+/)) {
        if (index(record, 'zapret') == -1) continue;
        let package = match(record, format == 'apk' ? /(^|\n)P:([^\n]+)/ : /(^|\n)Package: *([^\n]+)/);
        if (!package || (package[2] != 'zapret' && package[2] != 'luci-app-zapret')) continue;
        let fields = {};
        for (let line in split(record, '\n')) {
            let m = match(line, /^([^:]+):[ \t]*(.*)$/);
            if (m) fields[m[1]] = m[2];
        }
        let name = fields[format == 'apk' ? 'P' : 'Package'];
        let version = fields[format == 'apk' ? 'V' : 'Version'];
        if (name != 'zapret' && name != 'luci-app-zapret') continue;
        if (format != 'apk' && !match(fields.Status || '', /(^| )installed$/)) continue;
        if (type(version) == 'string' && length(version) <= 100 && match(version, /^[A-Za-z0-9_.+~-]+$/)) result[name] = version;
    }
    return result;
};

function package_versions(ctx) {
    for (let item in [['/lib/apk/db/installed', 'apk'], ['/usr/lib/opkg/status', 'opkg']]) {
        let path = ctx.root + item[0];
        if (fs.stat(path)) return parse_packages(read(path, 8388608), item[1]);
    }
    return {};
};

function configured_strategy(ctx) {
    if (!fs.stat(ctx.config)) return '';
    // root accepts neither quotes nor shell metacharacters in settings().
    let uci = "uci -c '" + ctx.root + "/etc/config' -q get ";
    let proc = fs.popen(uci + "'zapret.@main[0].NFQWS_OPT' 2>/dev/null || " +
        uci + "'zapret.@main[0]' >/dev/null 2>&1", 'r');
    check(proc != null, 'не удалось прочитать стратегию UCI');
    let body = '';
    while (true) {
        let chunk = proc.read(4096);
        if (chunk == null || !length(chunk)) break;
        body += chunk;
        if (length(body) > 65536) { proc.close(); die('слишком большая стратегия UCI'); }
    }
    check(proc.close() == 0, 'не удалось прочитать NFQWS_OPT');
    return body;
};

function normalized_strategy(body) {
    return join('--new\n', map(strategy_sections(body), (section) => section.body));
};

function inspect_strategy(body, list) {
    let sections = strategy_sections(body), references = [], by_name = {}, overrides = {};
    let wanted = map(sections, (s) => strategy_key(s.label));
    let labelled = length(filter(sections, (s) => s.label == null)) == 0;
    for (let candidate in list) {
        let name = strategy_key(candidate.name);
        if (by_name[name] || (labelled && index(wanted, name) == -1)) continue;
        let ref = { name, body: normalized_strategy(candidate.body) };
        by_name[name] = ref; push(references, ref);
    }
    // A named replacement accounts for precisely the profiles removed by the editor.
    // Arbitrary changes to the remaining Flowseal parameters still fail comparison.
    for (let section in sections) {
        let name = strategy_key(section.label), ref = by_name[name], group = strategy_group(name);
        if (group && ref && ref.body == section.body && !section.boundary_missing) overrides[group] = true;
    }
    let result = [];
    for (let section in sections) {
        if (section.label != null) {
            let name = strategy_key(section.label), ref = by_name[name];
            let exact = ref && ref.body == section.body;
            if (!exact && ref && match(name, /^general(_|$)/)) {
                let remaining = filter(split(ref.body, '--new\n'), (block) => !overrides[profile_group(block)]);
                exact = join('--new\n', remaining) == section.body;
            }
            push(result, { name, body: section.body, changed: !exact || section.boundary_missing });
            continue;
        }
        // Legacy configs: match complete consecutive presets, preferring the longest.
        let blocks = split(section.body, '--new\n');
        for (let i = 0; i < length(blocks);) {
            let found = null, count = 0;
            for (let ref in references) {
                let parts = split(ref.body, '--new\n');
                if (!length(ref.body) || length(parts) <= count || i + length(parts) > length(blocks)) continue;
                if (join('--new\n', slice(blocks, i, i + length(parts))) == ref.body) { found = ref; count = length(parts); }
            }
            push(result, { name: found ? found.name : null,
                body: join('--new\n', slice(blocks, i, i + (found ? count : 1))), changed: false });
            i += found ? count : 1;
        }
    }
    return result;
};

function strategy_summary(sections) {
    if (!length(sections)) return 'не выбрана';
    if (!length(filter(sections, (s) => s.name != null))) return 'кастомная';
    return join(' + ', map(sections, (s) => s.name == null ? 'кастомный блок' : s.name + (s.changed ? ' (изменена)' : '')));
};

function identify_strategy(body, list, state) {
    if (!length(normalize_options(body))) return 'не выбрана';
    if (state == null) return 'кастомная';
    return applied_status(strategy_hash(body), state, applied_catalog_hash(state, list), false);
};

function reference_catalog(ctx, wanted) {
    let list = [];
    for (let kind in ['flowseal', 'manager']) {
        let path = ctx.state + '/' + kind + '.json';
        if (!fs.stat(path)) continue;
        try { list = [...list, ...parse_catalog(ctx, json(read(path, ctx.max_file_bytes)).catalog, wanted)]; }
        catch (e) { /* Invalid cached presets cannot hide the actual configuration. */ }
    }
    return [...list, ...catalog(ctx, null, wanted)];
};

function strategy_state(ctx, summary_only) {
    let body = configured_strategy(ctx), state = null;
    if (!length(normalize_options(body))) return { summary: 'не выбрана', sections: [] };
    try { state = read_applied(ctx); } catch (e) { /* An invalid baseline cannot establish provenance. */ }
    if (summary_only) {
        let names = applied_names(state);
        let list = length(filter(names, (name) => name != null)) ? reference_catalog(ctx, names) : [];
        return { summary: identify_strategy(body, list, state), sections: [] };
    }
    let raw = strategy_sections(body);
    let wanted = length(filter(raw, (s) => s.label == null)) ? null :
        [...map(raw, (s) => strategy_key(s.label)), ...applied_names(state)];
    let list = reference_catalog(ctx, wanted);
    return { summary: identify_strategy(body, list, state), sections: inspect_strategy(body, list) };
};

function group_state(sections, group) {
    let names = [];
    for (let section in sections) {
        let family = strategy_group(section.name);
        let belongs = family == group;
        if (family == null) {
            belongs = length(filter(split(section.body, '--new\n'), (block) => profile_group(block) == group ||
                (group == 'discord' && index(block, '--filter-l7=discord,stun') != -1))) > 0;
        }
        if (belongs) push(names, section.name == null ? 'кастомный блок' : section.name + (section.changed ? ' (изменена)' : ''));
    }
    return length(names) ? join(' + ', names) : '[отключено]';
};

function procd_running(reply) {
    check(type(reply) == 'object', 'неверный ответ procd');
    if (reply.zapret == null) return false;
    check(type(reply.zapret.instances) == 'object', 'procd не вернул экземпляры Zapret');
    for (let key, instance in reply.zapret.instances) if (instance.running == true) return true;
    return false;
};

function service_running(ctx) {
    let ubus = ctx.root + '/bin/ubus';
    if (fs.stat(ubus)) {
        let proc = fs.popen("'" + ubus + "' -t 1 call service list '{\"name\":\"zapret\"}' 2>/dev/null", 'r');
        if (proc == null) return null;
        let reply = proc.read(65537), rc = proc.close();
        if (rc != 0 || reply == null || length(reply) > 65536) return null;
        try { return procd_running(json(reply)); } catch (e) { return null; }
    }
    let init = ctx.root + '/etc/init.d/zapret';
    return fs.stat(init) != null && system(['/bin/sh', '-c',
__JZM_JZM_UCODE_3__
)
export JZM_UCODE_3

JZM_UCODE_4=$(cat <<'__JZM_JZM_UCODE_4__'
'exec "$1" running >/dev/null 2>&1', 'jzm-status', init]) == 0;
};

function zapret_status(ctx) {
    let versions = package_versions(ctx), init = ctx.root + '/etc/init.d/zapret';
    let installed = versions.zapret != null || (fs.stat(init) != null && fs.stat(ctx.config) != null);
    let running = installed ? service_running(ctx) : false;
    let strategy = 'не выбрана';
    if (installed) {
        try { strategy = strategy_state(ctx, true).summary; }
        catch (e) { strategy = 'не удалось прочитать: ' + e.message; }
    }
    return { installed, running, version: versions.zapret || (installed ? 'неизвестна (без записи пакета)' : '—'),
        luci: versions['luci-app-zapret'] || null, strategy };
};

function release_compare(a, b) {
    let left = match(a, /^v?([0-9]+(\.[0-9]+)*)(-r[0-9]+)?$/);
    let right = match(b, /^v?([0-9]+(\.[0-9]+)*)(-r[0-9]+)?$/);
    check(left && right, 'не удалось сравнить версии Zapret; автоматическая переустановка отменена');
    left = split(left[1], '.'); right = split(right[1], '.');
    for (let i = 0; i < length(left) || i < length(right); i++) {
        let x = +(left[i] || 0), y = +(right[i] || 0);
        if (x != y) return x > y ? 1 : -1;
    }
    return 0;
};

function release_plan(versions, latest) {
    let core = versions.zapret, luci = versions['luci-app-zapret'];
    if (!core || release_compare(core, latest) < 0) return 'both';
    if (!luci || release_compare(luci, latest) < 0) {
        check(release_compare(core, latest) == 0, 'установлен более новый Zapret; подходящий LuCI отсутствует в этом релизе');
        return 'luci';
    }
    return 'none';
};

// ---- src/lib/sources.uc ----

function github_response(response) {
    let first = index(response, '\n'), tail = substr(response, first + 1), next = index(tail, '\n');
    check(first == 3 && next != -1, 'неверный ответ HTTP от GitHub API');
    let second = first + 1 + next;
    let status = substr(response, 0, first), remaining = substr(response, first + 1, second - first - 1);
    let body = substr(response, second + 1);
    check(match(status, /^[1-5][0-9]{2}$/), 'неверный статус HTTP от GitHub API');
    check(!(status == '429' || (status == '403' && (remaining == '0' ||
        match(lc(body), /rate limit exceeded|secondary rate limit/)))),
        'Превышен лимит запросов GitHub API (60/час на ваш IP). Попробуйте позже или используйте встроенные стратегии');
    check(substr(status, 0, 1) == '2', 'GitHub API: ошибка HTTP ' + status);
    return body;
};

function remote(ctx, url) {
    if (substr(url, 0, 23) == 'https://api.github.com/')
        return github_response(output(ctx, 'github-download', [ctx.connect_timeout,
            ctx.request_timeout, ctx.max_file_bytes - 64, url]));
    return output(ctx, 'download', [ctx.connect_timeout, ctx.request_timeout, ctx.max_file_bytes, url]);
}

function revision(ctx, repo) {
    let reply = json(remote(ctx, 'https://api.github.com/repos/' + repo + '/commits/' + ctx.sources.branch));
    check(type(reply.sha) == 'string' && match(reply.sha, /^[a-f0-9]{40}$/), 'источник не вернул commit SHA');
    return reply.sha;
}

function raw_url(repo, rev, path) {
    check(match(rev, /^[a-f0-9]{40}$/) && match(path, /^[A-Za-z0-9_ .()\/-]+$/) &&
          !match(path, /(^|\/)\.\.?(\/|$)/), 'неверный путь источника');
    return 'https://raw.githubusercontent.com/' + repo + '/' + rev + '/' + replace(path, / /g, '%20');
}

function manager_catalog(ctx, source, youtube) {
    // Accept upstream's safe "--option value" spelling, store canonical --option=value.
    let canonical_options = (body) => join('\n', map(split(body, '\n'), (line) => {
        let option = match(trim(line), /^(--[A-Za-z0-9][A-Za-z0-9_-]*)[ \t]+([A-Za-z0-9_.,:\/+=@%{}!~-]+)$/);
        return option ? option[1] + '=' + option[2] : line;
    }));
    let imported_body = (body) => validate_body(canonical_options(body));
    let result = [];
    for (let line in split(source, '\n')) {
        let m = match(line, /^strategy_(v[0-9]+)\(\) \{ printf /);
        if (m) {
            let quoted = split(line, '"'), args = [];
            for (let i = 1; i < length(quoted); i += 2)
                if (substr(quoted[i], 0, 2) == '--') push(args, quoted[i]);
            push(result, { name: m[1], body: imported_body(join('\n', args)) });
        }
        m = match(line, /^(Dv[0-9]+)=\$'([^']*)'/);
        if (m) push(result, { name: m[1], body: imported_body(replace(m[2], /\\n/g, '\n')) });
    }
    check(length(result), 'в исходном менеджере не найдены стратегии v/Dv');
    for (let s in parse_catalog(ctx, canonical_options(youtube))) push(result, s);
    for (let s in catalog(ctx)) if (match(s.name, /^Gv/)) push(result, s);
    return join('', map(result, (s) => '#' + s.name + '\n' + s.body));
};

function windows_tokens(text) {
    let args = [], word = '', quoted = false;
    for (let i = 0; i < length(text); i++) {
        let c = substr(text, i, 1);
        if (c == '"') { quoted = !quoted; continue; }
        if (c == '^') {
            let next = substr(text, i + 1, 1);
            if (next == '!') { word += '^!'; i++; continue; }
            check(next == '\n' || next == '\r' || next == ' ', 'неподдерживаемое экранирование BAT');
            continue;
        }
        if (!quoted && match(c, /^[[:space:]]$/)) {
            if (length(word)) { push(args, word); word = ''; }
        }
        else word += c;
    }
    check(!quoted, 'незакрытая кавычка BAT');
    if (length(word)) push(args, word);
    return args;
}

function flowseal_strategy(ctx, text) {
    let command = '', active = false;
    for (let raw in split(replace(text, /\r/g, ''), '\n')) {
        let line = trim(raw);
        if (!active && match(line, /^start[[:space:]].*winws\.exe/i)) {
            active = true;
            line = substr(line, index(lc(line), 'winws.exe') + 9);
            line = substr(line, index(line, '--'));
        }
        if (!active) continue;
        command += line + '\n';
        if (!match(line, /\^$/)) break;
    }
    check(active, 'команда winws в BAT не найдена');
    let blocks = [[]];
    for (let arg in windows_tokens(command)) {
        if (arg == '--new') { push(blocks, []); continue; }
        if (match(arg, /^--wf-/)) continue;
        check(substr(arg, 0, 2) == '--', 'неожиданный токен BAT: ' + arg);
        push(blocks[-1], arg);
    }
    let result = [], assets = {};
    for (let block in blocks) {
        let joined = join(' ', block);
        let supported = match(joined, /^--filter-udp=19294-19344,50000-50100/) ||
            match(joined, /^--filter-tcp=%GameFilterTCP%/) || match(joined, /^--filter-udp=%GameFilterUDP%/) ||
            match(joined, /^--filter-tcp=2053,2083,2087,2096,8443/) ||
            match(joined, /^--filter-tcp=443 --hostlist=%LISTS%list-google.txt/) ||
            match(joined, /^--filter-tcp=80,443 --hostlist=%LISTS%list-general.txt/);
        if (!supported) continue;
        let converted = [];
        for (let arg in block) {
            if (match(arg, /^--ipset(-exclude)?=/) ||
                match(arg, /^--hostlist=%LISTS%list-general(-user)?\.txt$/) ||
                arg == '--hostlist-exclude=%LISTS%list-exclude-user.txt') continue;
            arg = replace(arg, '%GameFilterTCP%', ctx.sources.tcp_ports);
            arg = replace(arg, '%GameFilterUDP%', ctx.sources.udp_ports);
            arg = replace(arg, '%LISTS%list-google.txt', '/opt/zapret/ipset/zapret-hosts-google.txt');
            arg = replace(arg, '%LISTS%list-exclude.txt', '/opt/zapret/ipset/zapret-hosts-user-exclude.txt');
            arg = replace(arg, '^!', '%BIN%tls_clienthello_www_google_com.bin');
            let m = match(arg, /%BIN%([A-Za-z0-9_.-]+\.bin)/);
            if (m) {
                let original = m[1], local = ctx.sources.fake_aliases[original] || original;
                check(match(local, /^[A-Za-z0-9_.-]+\.bin$/), 'неверное имя fake-файла');
                let remote = match(original, /^ACTIVE_/) ? local : original;
                assets[local] = 'bin/' + remote;
                arg = replace(arg, '%BIN%' + original, '/opt/zapret/files/fake/' + local);
            }
            check(!match(arg, /%[A-Za-z_][A-Za-z0-9_]*%/), 'неизвестная переменная BAT: ' + arg);
            push(converted, arg);
        }
        if (length(converted)) push(result, join('\n', converted));
    }
    check(length(result) && length(filter(result, (block) =>
        index(block, '--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt') != -1 ||
        match(block, /^--filter-tcp=80,443(\n|,)/))),
        'нет полной переносимой TCP/YouTube-стратегии; частичные блоки не импортированы');
    return { body: validate_body(join('\n--new\n', result)), assets };
};

function source_file(ctx, kind) {
    check(kind == 'manager' || kind == 'flowseal', 'неизвестный источник');
    return ctx.state + '/' + kind + '.json';
};

function source_data(ctx, kind, wanted) {
    let file = source_file(ctx, kind);
    if (!fs.stat(file)) {
        check(kind == 'manager', 'сначала обновите каталог Flowseal в меню');
        let text = resource(ctx.home, 'strategies.txt');
        return { catalog: text, strategies: parse_catalog(ctx, text, wanted), assets: {}, revision: 'встроенный' };
    }
    let value = json(read(file, ctx.max_file_bytes));
    check(value.format == 1 && value.source == kind && type(value.revision) == 'string' &&
          length(value.revision) == 40 && match(value.revision, /^[a-f0-9]+$/) &&
          type(value.assets) == 'object', 'повреждён каталог источника');
    check(type(value.catalog) == 'string', 'повреждён текст каталога источника');
    value.strategies = parse_catalog(ctx, value.catalog, wanted);
    return value;
};

function refresh_source(ctx, kind) {
    source_file(ctx, kind);
    let repo = ctx.sources[kind + '_repo'], rev = revision(ctx, repo), assets = {}, text = '', skipped = [];
    if (kind == 'manager') {
        text = manager_catalog(ctx, remote(ctx, raw_url(repo, rev, 'Zapret-Manager.sh')),
            remote(ctx, raw_url(repo, rev, 'files/StrYoutube')));
    }
    else {
        let tree = json(remote(ctx, 'https://api.github.com/repos/' + repo + '/git/trees/' + rev + '?recursive=1'));
        check(type(tree.tree) == 'array' && !tree.truncated, 'неполное дерево репозитория Flowseal');
        for (let file in tree.tree) {
            if (file.type != 'blob' || !match(file.path, /^general[A-Za-z0-9_ .()-]*\.bat$/i)) continue;
            try {
                let converted = flowseal_strategy(ctx, remote(ctx, raw_url(repo, rev, file.path)));
                let name = strategy_key(replace(replace(file.path, /\.bat$/i, ''), /[^A-Za-z0-9_.-]+/g, '_'));
                text += '#' + name + '\n' + converted.body;
                for (let local, path in converted.assets) assets[local] = path;
            }
            catch (e) { push(skipped, file.path + ': ' + e.message); }
        }
    }
    let list = parse_catalog(ctx, text);
    let value = { format: 1, source: kind, revision: rev, catalog: text, assets, skipped };
    let body = sprintf('%J\n', value);
    check(length(body) <= ctx.max_file_bytes, 'каталог источника слишком большой');
    send(ctx, 'source-write', [kind], body);
    printf('Обновлено стратегий: %d\nРевизия: %s\n', length(list), rev);
    for (let line in skipped) printf('Пропущено: %s\n', line);
};

function prepare_assets(ctx, kind, body, prepared) {
    let data = prepared || source_data(ctx, kind, []), repo = ctx.sources[kind + '_repo'], pinned = null;
    for (let line in split(body, '\n')) {
        let m = match(line, /^--[^=]+=\/opt\/zapret\/files\/fake\/([A-Za-z0-9_.-]+\.bin)$/);
        if (!m || fs.stat(ctx.base + '/files/fake/' + m[1])) continue;
        let local = m[1], path = data.assets[local];
        // Manager strategies use the same supplemental fake files as the original manager.
        if (kind == 'manager') {
            repo = ctx.sources.flowseal_repo;
            let aliases = { '4pda.bin': 'tls_clienthello_4pda_to.bin',
                'tls_clienthello_www_onetrust_com.bin': 'tls_clienthello_max_ru.bin' };
            path = 'bin/' + (aliases[local] || local);
        }
        check(path != null, 'источник не содержит fake-файл: ' + local);
        if (kind == 'manager' && pinned == null) pinned = revision(ctx, repo);
        let rev = kind == 'manager' ? pinned : data.revision;
        let dir = tempdir();
        try {
            run(ctx, 'check-space', [int((ctx.max_file_bytes + 1023) / 1024)]);
            run(ctx, 'download', [dir + '/blob', ctx.connect_timeout, ctx.request_timeout,
                ctx.max_file_bytes, raw_url(repo, rev, path)]);
            run(ctx, 'resource-write', [dir + '/blob', local]);
        }
        catch (e) { fs.unlink(dir + '/blob'); fs.rmdir(dir); die(e.message); }
        fs.unlink(dir + '/blob'); fs.rmdir(dir);
    }
};

function release_install(ctx) {
    let release = json(remote(ctx, 'https://api.github.com/repos/' + ctx.sources.installer_repo + '/releases/latest'));
    check(type(release.tag_name) == 'string' && match(release.tag_name, /^v[0-9.]+$/) &&
          type(release.assets) == 'array', 'неверные данные релиза Zapret');
    let versions = package_versions(ctx);
    check(versions.zapret || !fs.stat(ctx.root + '/etc/init.d/zapret'),
        'Zapret найден без записи версии пакета; автоматическая переустановка отменена');
    let plan = release_plan(versions, release.tag_name);
    if (plan == 'none') { print('Zapret и LuCI актуальны. Новых версий нет, переустановка не требуется.\n'); return 'none'; }
    let arch = trim(output(ctx, 'architecture'));
    check(match(arch, /^[A-Za-z0-9_-]+$/), 'не удалось определить архитектуру OpenWrt');
    let name = 'zapret_' + release.tag_name + '_' + arch + '.zip';
    let selected = filter(release.assets, (a) => a.name == name);
    check(length(selected) == 1, 'нет сборки Zapret для архитектуры ' + arch);
    let url = 'https://github.com/' + ctx.sources.installer_repo + '/releases/download/' + release.tag_name + '/' + name;
    check(selected[0].browser_download_url == url && type(selected[0].size) == 'int' &&
        selected[0].size > 0 && selected[0].size <= 16777216, 'неверный файл релиза');
    let digest = selected[0].digest || '';
    check(digest == '' || match(digest, /^sha256:[a-f0-9]{64}$/), 'неверный SHA256 релиза');
    printf('Релиз Zapret: %s\n%s\n', release.tag_name, plan == 'luci' ?
        'Устанавливается недостающий LuCI-пакет для этой версии Zapret.' : 'Устанавливаются Zapret и luci-app-zapret.');
    run(ctx, 'release-install', [url, substr(digest, 7), ctx.connect_timeout, ctx.request_timeout, plan, int((selected[0].size + 1023) / 1024)]);
    return plan;
};

// ---- src/lib/manager.uc ----

function newer_version(candidate, current) {
    check(type(candidate) == 'string' && match(candidate, /^[0-9]+\.[0-9]+\.[0-9]+$/), 'неверная версия менеджера');
    let a = split(candidate, '.'), b = split(current, '.');
    for (let i = 0; i < 3; i++) {
        if (+a[i] != +b[i]) return +a[i] > +b[i];
    }
    return false;
};

function shell_value(name, body) {
    let marker = '__JZM_' + name + '__';
    return name + "=$(cat <<'" + marker + "'\n" + trim(body) + '\n' + marker + '\n)\nexport ' + name + '\n\n';
}

function render_bundle(ctx) {
    if (embedded_header() == null) {
        check(system(['/bin/sh', ctx.home + '/tools/bundle.sh']) == 0, 'не удалось собрать jzm');
        return read(ctx.home + '/dist/just-zapret-manager.sh', ctx.max_file_bytes);
    }
    let body = embedded_header() + shell_value('JZM_BACKEND', getenv('JZM_BACKEND'));
    let count = +getenv('JZM_PARTS');
    for (let i = 1; i <= count; i++) body += shell_value('JZM_UCODE_' + i, getenv('JZM_UCODE_' + i));
    return body + 'JZM_PARTS=' + count + '\nexport JZM_PARTS\n' + embedded_footer();
};

function install_manager(ctx) {
    if (!getenv('ZM_TRANSACTION')) { check(invoke(ctx, ['manager-install']) == 0, 'не удалось установить менеджер'); return; }
    let destination = getenv('DESTDIR') || ctx.root;
    check(destination == '' || (match(destination, /^\/[A-Za-z0-9_./ -]+$/) && !match(destination, /(^|\/)\.\.?(\/|$)/)), 'неверный DESTDIR');
    send(ctx, 'manager-install', [destination], render_bundle(ctx));
    let config = embedded_config() || json(read(ctx.home + '/data/manager.json', 65536));
    send(ctx, 'manager-config-init', [destination], sprintf('%J\n', config));
    // Early builds saved an empty update source; migrate only that known default.
    let saved = destination + '/etc/zapret-manager/manager-config.json';
    let previous = null;
    try { previous = json(read(saved, 65536)); } catch (e) { /* Preserve custom files. */ }
    if (previous?.updater?.repo == '' && index(['dist/Zapret-Manager.sh', 'dist/just-zapret-manager.sh'], previous.updater.path) != -1) {
        previous.updater = config.updater;
        send(ctx, 'state-write', ['manager-config.json'], sprintf('%J\n', previous));
    }
    printf('Установлено: %s/usr/bin/jzm\nКонфигурация: %s/etc/zapret-manager/manager-config.json\n', destination, destination);
};

function update_origin(ctx) {
    return ctx.updater.repo + '/' + ctx.updater.branch + '/' + ctx.updater.path;
}

function update_remote(ctx, url) {
    // Every URL component is validated by settings(); no shell metacharacters are accepted.
    check(match(url, /^https:\/\/[A-Za-z0-9_.\/-]+$/), 'неверный URL обновления');
    let cmd = "curl --fail --silent --show-error --location --max-redirs 3 --proto '=https' --proto-redir '=https'" +
        ' --connect-timeout ' + ctx.connect_timeout + ' --max-time ' + ctx.request_timeout +
        ' --max-filesize ' + ctx.max_file_bytes + " '" + url + "' 2>/dev/null";
    let proc = fs.popen(cmd, 'r');
    check(proc != null, 'не удалось запустить curl');
    let body = '';
    while (true) {
        let chunk = proc.read(4096);
        if (chunk == null || !length(chunk)) break;
        body += chunk;
        if (length(body) > ctx.max_file_bytes) { proc.close(); die('обновление слишком большое'); }
    }
    check(proc.close() == 0 && length(body), 'не удалось получить обновление');
    return body;
}

function update_status(ctx) {
    if (!length(ctx.updater.repo)) return { label: 'источник не настроен', available: false };
    let path = ctx.state + '/update.json';
    try {
        let data = json(read(path, 65536));
        check(data.origin == update_origin(ctx) && match(data.revision, /^[a-f0-9]{40}$/), 'неверный кэш обновления');
        data.available = newer_version(data.version, VERSION);
        data.label = data.version + (data.available ? ' — доступно обновление [u]' : '');
        return data;
    }
    catch (e) { return { label: 'ещё не проверена', available: false }; }
};

function check_update(ctx) {
    check(length(ctx.updater.repo), 'источник обновлений не настроен в updater.repo');
    let base = 'https://api.github.com/repos/' + ctx.updater.repo;
    let revision = json(update_remote(ctx, base + '/commits/' + ctx.updater.branch)).sha;
    check(type(revision) == 'string' && match(revision, /^[a-f0-9]{40}$/), 'неверная ревизия обновления');
    let body = update_remote(ctx, 'https://raw.githubusercontent.com/' + ctx.updater.repo + '/' + revision + '/' + ctx.updater.path);
    let version = match(body, /(^|\n)# JZM_VERSION=([0-9]+\.[0-9]+\.[0-9]+)(\n|$)/);
    check(version && match(body, /(^|\n)# JZM_FORMAT=2(\n|$)/), 'источник не содержит совместимую сборку JZM');
    newer_version(version[2], VERSION);
    let data = { origin: update_origin(ctx), revision, version: version[2], checked: time() };
    if (getenv('ZM_TRANSACTION')) cache_update(ctx, data);
    else check(invoke(ctx, ['manager-cache', sprintf('%J', data)]) == 0, 'не удалось сохранить проверку обновления');
    return update_status(ctx);
};

function cache_update(ctx, data) {
    check(getenv('ZM_TRANSACTION') && type(data) == 'object' && data.origin == update_origin(ctx) &&
        type(data.revision) == 'string' && match(data.revision, /^[a-f0-9]{40}$/) &&
        type(data.checked) == 'int' && data.checked > 0, 'неверный кэш обновления');
    newer_version(data.version, VERSION);
    if (getenv('JZM_BACKGROUND_UPDATE') == '1' && fs.stat(ctx.root + '/usr/bin/jzm') == null) return;
    send(ctx, 'state-write', ['update.json'], sprintf('%J\n', data));
};

function start_update_check(ctx) {
    if (!length(ctx.updater.repo) || ctx.root != '' || !getenv('JZM_BOOTSTRAP') || fs.stat('/usr/bin/jzm') == null) return;
    let status = update_status(ctx);
    if (status.checked != null && time() - status.checked < 21600) return;
    let config = fs.stat(ctx.file) ? ['--config', ctx.file] : [];
    system(['/bin/sh', '-c',
        'JZM_BACKGROUND_UPDATE=1 JZM_MODE=command ucode -S -e "$JZM_BOOTSTRAP" -- "$@" </dev/null >/dev/null 2>&1 &',
        'jzm-update', ...config, 'manager-check']);
};

function apply_update(ctx) {
    if (!getenv('ZM_TRANSACTION')) { check(invoke(ctx, ['manager-update']) == 0, 'не удалось обновить менеджер'); return; }
    let info = update_status(ctx);
    check(info.available, 'новой версии нет; сначала проверьте обновления');
    let body = update_remote(ctx, 'https://raw.githubusercontent.com/' + ctx.updater.repo + '/' + info.revision + '/' + ctx.updater.path);
    check(index(body, '\n# JZM_VERSION=' + info.version + '\n') != -1 && match(body, /(^|\n)# JZM_FORMAT=2(\n|$)/), 'версия загруженного файла не совпала');
    let dir = tempdir();
    try {
        let path = dir + '/jzm';
        check(fs.writefile(path, body) == length(body), 'не удалось записать обновление');
        run(ctx, 'manager-validate', [path]);
        run(ctx, 'manager-install', [path, ctx.root]);
    }
    catch (e) { fs.unlink(dir + '/jzm'); fs.rmdir(dir); die(e.message); }
    fs.unlink(dir + '/jzm'); fs.rmdir(dir);
    printf('Менеджер обновлён до %s. Предыдущая сборка: /usr/bin/jzm.previous\nЗапустите jzm заново.\n', info.version);
};

// ---- src/lib/menu.uc ----

let ended = false;

function paint(code, text) {
    let enabled = getenv('JZM_COLOR') == 'always' || (fs.stdout.isatty() &&
        getenv('NO_COLOR') == null && getenv('TERM') != 'dumb');
    return enabled ? '\x1b[' + code + 'm' + text + '\x1b[0m' : text;
}
__JZM_JZM_UCODE_4__
)
export JZM_UCODE_4

JZM_UCODE_5=$(cat <<'__JZM_JZM_UCODE_5__'
function menu_line(key, text) { printf('  %s %s\n', paint('36;1', key + '.'), text); }

function prompt(label, fallback) {
    fs.stdout.write(paint('33;1', label) + (fallback != null ? ' [' + fallback + ']' : '') + ': ');
    fs.stdout.flush();
    let line = '';
    while (true) {
        let c = fs.stdin.read(1);
        if (c == null || !length(c)) { ended = true; return null; }
        if (c == '\n') break;
        if (c != '\r') line += c;
        check(length(line) <= 4096, 'слишком длинный ввод');
    }
    line = trim(line);
    return !length(line) && fallback != null ? '' + fallback : line;
}

function pause() { if (!ended) prompt('Нажмите Enter', null); }

function screen(title) {
    if (fs.stdout.isatty()) print('\x1b[2J\x1b[H');
    print('\n────────────────────────────────────────\n');
    printf('  %s\n', paint('36;1', 'JZM · ' + title));
    print('────────────────────────────────────────\n');
}

function choice(title, labels) {
    screen(title);
    for (let i = 0; i < length(labels); i++) menu_line(i + 1, labels[i]);
    menu_line('0', 'Назад'); print('\n');
    let value = prompt('Выберите пункт', null);
    if (value == null || value == '' || value == '0') return 0;
    check(match(value, /^[0-9]+$/) && +value >= 1 && +value <= length(labels), 'нет такого пункта');
    return +value;
}

let menu_executor = null;

function command(ctx, args) {
    let rc = menu_executor ? menu_executor([...(fs.stat(ctx.file) ? ['--config', ctx.file] : []), ...args]) : invoke(ctx, args);
    check(rc == 0, 'действие не выполнено; причина указана выше');
}

function perform(fn) {
    try { fn(); }
    catch (e) { printf('\n%s\n', paint('31;1', 'Ошибка: ' + e.message)); }
    pause();
}

function confirm(text) {
    while (!ended) {
        let answer = prompt(text + '? [y/N]', null);
        if (answer == null || answer == '' || lc(answer) == 'n') return false;
        if (lc(answer) == 'y') return true;
        print('Введите y или n. Enter — отменить.\n');
    }
    return false;
}

function local_file(label, fallback) {
    let value = prompt(label, fallback);
    check(value != null && length(value), 'путь не указан');
    return value;
}

function current_strategy(state) {
    let text = state.summary;
    printf('Текущая стратегия: %s\n\n', paint('35;1', length(state.sections) > 1 ? '[' + text + ']' : text));
}

function choose_strategy(ctx, kind, group) {
    let page = 0, list = null, revision = '', problem = '';
    while (!ended) {
        if (list == null) {
            try {
                let data = source_data(ctx, kind);
                list = data.strategies; revision = data.revision;
                if (group != null) list = filter(list, (s) => strategy_group(s.name) == group);
                sort(list, strategy_order);
                problem = length(list) ? '' : 'В каталоге нет стратегий этой группы.';
            }
            catch (e) { list = []; problem = e.message; }
        }
        let state = strategy_state(ctx);
        screen(kind == 'flowseal' ? 'Пресеты Flowseal' : 'Выбор · ' +
            { base: 'Базовый трафик', youtube: 'YouTube', discord: 'Discord', games: 'Игры' }[group]);
        if (kind == 'flowseal') current_strategy(state);
        else printf('Сейчас: %s\n\n', paint('35;1', group_state(state.sections, group)));
        let first = page * 12;
        if (length(problem)) printf('%s\n\n', paint('33', problem));
        else {
            for (let i = first; i < length(list) && i < first + 12; i++) {
                let active = length(filter(state.sections, (s) => s.name == strategy_key(list[i].name) && !s.changed)) > 0;
                menu_line(i + 1, paint(active ? '32;1' : '0', strategy_title(list[i].name)) + (active ? '  ← выбрана' : ''));
            }
            printf('\n%s\n', paint('2', 'Каталог: ' + (revision == 'встроенный' ? revision : substr(revision, 0, 8))));
        }
        if (length(list) > 12) printf('  n. Далее   p. Назад по списку   (%d/%d)\n', page + 1, int((length(list) + 11) / 12));
        menu_line('u', 'Обновить каталог');
        menu_line('d', kind == 'flowseal' ? 'Отключить Flowseal, оставить другие стратегии' : 'Отключить эту группу');
        menu_line('0', 'Отмена'); print('\n');
        let value = prompt('Выбор', null);
        if (value == null || value == '' || value == '0') return null;
        value = lc(value);
        if (value == 'd') return { disable: true };
        if (value == 'u') {
            perform(() => command(ctx, ['source', 'refresh', kind]));
            list = null; page = 0; continue;
        }
        if (value == 'n') { if (first + 12 < length(list)) page++; continue; }
        if (value == 'p') { if (page) page--; continue; }
        if (!match(value, /^[0-9]+$/) || +value <= first || +value > length(list) || +value > first + 12) {
            print('Нет такого пункта на этой странице.\n'); pause(); continue;
        }
        return list[+value - 1];
    }
    return null;
}

function edit_group(ctx, group) {
    let selected = choose_strategy(ctx, 'manager', group);
    if (!selected) return;
    let question = selected.disable ? 'Отключить группу, сохранив остальные стратегии' :
        'Применить ' + selected.name + ', сохранив остальные стратегии';
    if (!confirm(question)) return;
    perform(() => {
        command(ctx, selected.disable ? ['source', 'remove', 'manager', group] : ['source', 'group', 'manager', group, selected.name]);
        print('\n' + paint('32;1', 'Сохранено.') + '\n');
    });
}

function compose_menu(ctx) {
    let groups = ['base', 'youtube', 'discord', 'games'];
    let labels = ['Базовый трафик:', 'YouTube:       ', 'Discord:       ', 'Игры:          '];
    while (!ended) {
        let state = strategy_state(ctx), available = [];
        try { available = source_data(ctx, 'manager').strategies; } catch (e) { /* Picker offers catalog repair. */ }
        screen('Собрать стратегию'); current_strategy(state);
        for (let i = 0; i < length(groups); i++) {
            let names = filter(available, (s) => strategy_group(s.name) == groups[i]);
            sort(names, strategy_order);
            let hint = !length(names) ? 'нет в каталоге' : names[0].name + (length(names) > 1 ? '–' + names[-1].name : '');
            let value = group_state(state.sections, groups[i]);
            menu_line(i + 1, labels[i] + '  ' + paint(value == '[отключено]' ? '2' : '35;1', value) + '  ' + paint('2', '(' + hint + ')'));
        }
        print('\nВыберите группу: добавить, заменить или отключить.\n');
        print(paint('2', 'Изменения применяются сразу; остальные группы сохраняются.') + '\n');
        menu_line('0', 'Назад'); print('\n');
        let value = prompt('Выбор', null);
        if (value == null || value == '' || value == '0') return;
        if (!match(value, /^[1-4]$/)) { print('Нет такого пункта.\n'); pause(); continue; }
        edit_group(ctx, groups[+value - 1]);
    }
}

function test_menu(ctx) {
    while (!ended) {
        let c = choice('Тестирование и автоподбор', ['Проверить текущую стратегию', 'Сравнить стратегии Zapret Manager',
            'Сравнить стратегии Flowseal', 'Подобрать и применить лучшую', 'Настроить подбор по расписанию', 'Отключить расписание']);
        if (!c) return;
        perform(() => {
            if (c == 6) { command(ctx, ['schedule', 'off']); return; }
            let file = local_file('Файл с URL для тестов', '@default');
            if (c == 1) { command(ctx, ['test', file]); return; }
            let kind = c == 3 ? 'flowseal' : 'manager';
            if (c == 4 || c == 5) {
                let selected = choice('Источник стратегий', ['Zapret Manager', 'Flowseal']);
                if (!selected) return;
                kind = selected == 1 ? 'manager' : 'flowseal';
            }
            if (c == 5) {
                check(fs.stat(ctx.root + '/usr/bin/jzm') != null, 'сначала установите JZM через установщик');
                let hour = local_file('Час ежедневного запуска, 0–23', '4');
                command(ctx, ['targets', file]);
                command(ctx, ['source', 'export', kind, kind + '.txt']);
                command(ctx, ['schedule', hour, ctx.state + '/urls.txt', ctx.state + '/' + kind + '.txt']);
                return;
            }
            command(ctx, ['source', c == 4 ? 'auto-best' : 'benchmark', kind, file]);
        });
    }
}

function strategy_menu(ctx) {
    while (!ended) {
        screen('Zapret: Стратегии'); current_strategy(strategy_state(ctx));
        menu_line('1', 'Стратегии Flowseal');
        menu_line('2', 'Собрать: основная + YouTube + Discord + игры');
        menu_line('3', 'Тестирование и автоподбор');
        print('\n'); menu_line('f', 'Загрузить свою стратегию из файла');
        menu_line('0', 'Назад'); print('\n');
        let value = prompt('Выбор', null);
        if (value == null || value == '' || value == '0') return;
        if (value == '2') { compose_menu(ctx); continue; }
        if (value == '3') { test_menu(ctx); continue; }
        if (lc(value) == 'f') {
            perform(() => {
                let file = local_file('Файл стратегии', '/root/custom.txt');
                if (confirm('Заменить текущие стратегии содержимым файла')) command(ctx, ['strategy', 'import', file]);
            });
            continue;
        }
        if (value != '1') { print('Нет такого пункта.\n'); pause(); continue; }
        let selected = choose_strategy(ctx, 'flowseal', null);
        if (!selected) continue;
        if (confirm(selected.disable ? 'Отключить Flowseal, сохранив остальные стратегии' :
            'Заменить текущую композицию пресетом ' + strategy_title(selected.name))) {
            perform(() => {
                command(ctx, selected.disable ? ['source', 'remove', 'flowseal'] : ['source', 'apply', 'flowseal', selected.name]);
                print('\n' + paint('32;1', 'Сохранено.') + '\n');
            });
        }
    }
}

function install_menu(ctx) {
    while (!ended) {
        let state = zapret_status(ctx);
        let c = choice('Zapret · ' + (state.installed ? state.version : 'не установлен'),
            state.installed ? ['Обновить Zapret', 'Удалить Zapret', 'Удалить только JZM', 'Удалить всё: JZM + Zapret + LuCI'] :
                ['Установить Zapret', 'Удалить только JZM', 'Удалить всё: JZM + Zapret + LuCI']);
        if (!c) return;
        perform(() => {
            let manager_only = c == (state.installed ? 3 : 2);
            let everything = c == (state.installed ? 4 : 3);
            if (manager_only || everything) {
                print(manager_only ? 'Zapret, LuCI и текущие стратегии останутся. Расписание, правила и исключения JZM будут удалены.\n' :
                    'Будут удалены Zapret, LuCI, JZM, стратегии, списки, fake-файлы и резервные копии.\n');
                if (confirm(manager_only ? 'Удалить JZM и его данные' : 'Полностью удалить JZM и Zapret')) {
                    command(ctx, ['uninstall', manager_only ? 'manager' : 'all']);
                    print(manager_only ? 'JZM удалён. Zapret сохранён.\n' : 'JZM и Zapret удалены.\n');
                    ended = true;
                }
                return;
            }
            if (state.installed && c == 2) {
                if (confirm('Удалить Zapret и его LuCI-пакет')) command(ctx, ['remove']);
                return;
            }
            let source = choice(state.installed ? 'Источник обновления' : 'Источник установки',
                ['Сборка remittor: Zapret + LuCI', 'Настроенные feeds OpenWrt', 'Локальные пакеты']);
            if (!source) return;
            let args = [];
            if (source == 3) {
                push(args, local_file('Пакет Zapret (.ipk/.apk)', null));
                push(args, local_file('Пакет luci-app-zapret (.ipk/.apk)', null));
            }
            if (!confirm(state.installed ? 'Проверить и установить доступные обновления Zapret и LuCI' : 'Установить Zapret и LuCI')) return;
            command(ctx, [source == 1 ? (state.installed ? 'update-upstream' : 'install-upstream') :
                (state.installed ? 'update' : 'install'), ...args]);
        });
    }
}

function service_menu(ctx) {
    while (!ended) {
        let c = choice('Управление ' + ctx.profile, ['Запустить', 'Остановить', 'Перезапустить', 'Включить автозапуск', 'Выключить автозапуск']);
        if (!c) return;
        perform(() => command(ctx, ['service', ['start', 'stop', 'restart', 'enable', 'disable'][c - 1]]));
    }
}

function hosts_menu(ctx) {
    while (!ended) {
        let kinds = ['user', 'exclude', 'google'];
        let c = choice('Домены Zapret', ['Пользовательские домены', 'Исключения', 'YouTube / Google']);
        if (!c) return;
        let kind = kinds[c - 1];
        while (!ended) {
            let action = choice('Список: ' + kind, ['Показать', 'Добавить домены', 'Удалить домены', 'Заменить из файла', 'Обновить из источника']);
            if (!action) break;
            perform(() => {
                if (action == 1) command(ctx, ['hosts', kind, 'show']);
                if (action == 2 || action == 3) {
                    let text = local_file('Домены через пробел', null);
                    command(ctx, ['hosts', kind, action == 2 ? 'add' : 'remove', ...split(text, /[[:space:]]+/)]);
                }
                if (action == 4) command(ctx, ['hosts', kind, 'replace', local_file('Файл со списком доменов', null)]);
                if (action == 5) command(ctx, ['hosts', kind, 'refresh']);
            });
        }
    }
}

function config_menu(ctx) {
    while (!ended) {
        let c = choice('Настройки Zapret', ['Показать конфигурацию', 'IPv6', 'Режим фильтрации',
            'Порты TCP', 'Порты UDP', 'Пользовательские скрипты Zapret', 'Отладочный вывод', 'Исключить устройства из Zapret',
            'Совместимость: Flow Offloading', 'Блокировка QUIC (UDP 80/443)']);
        if (!c) return;
        perform(() => {
            if (c == 1) { command(ctx, ['config', 'show']); return; }
            if (c == 9 || c == 10) {
                command(ctx, ['network', 'status']);
                let action = choice(c == 9 ? 'Flow Offloading' : 'QUIC', c == 9 ?
                    ['Отключить ускорение для совместимости с Zapret', 'Вернуть прежние настройки ускорения'] :
                    ['Блокировать QUIC, использовать TCP', 'Снять блокировку QUIC, созданную JZM']);
                if (action) command(ctx, ['network', c == 9 ? 'offload' : 'quic',
                    c == 9 ? (action == 1 ? 'disable' : 'restore') : (action == 1 ? 'on' : 'off')]);
                return;
            }
            if (c == 8) {
                let devices = device_list(ctx), current = excluded(ctx);
                print('Устройства из DHCP; исключённые проходят без обработки Zapret.\n');
                for (let i = 0; i < length(devices); i++) printf('%d) %s %s %s\n', i + 1,
                    index(current, devices[i].ip) == -1 ? '[Zapret]' : '[Исключён]', devices[i].ip, devices[i].name);
                print('a) Ввести IP вручную   c) Очистить исключения   0) Назад\n');
                let selected = prompt('Устройство', null);
                if (selected == null || selected == '' || selected == '0') return;
                if (selected == 'c') { command(ctx, ['devices', 'clear']); return; }
                let ip;
                if (selected == 'a') ip = local_file('IPv4 устройства', null);
                else {
                    check(match(selected, /^[0-9]+$/) && +selected >= 1 && +selected <= length(devices), 'нет такого устройства');
                    ip = devices[+selected - 1].ip;
                }
                command(ctx, ['devices', 'toggle', ip]);
                return;
            }
            let key, value;
            if (c == 2 || c == 6 || c == 7) {
                let enabled = prompt('1 — включить, 0 — выключить', null);
                check(enabled == '0' || enabled == '1', 'введите 0 или 1');
                key = c == 2 ? 'DISABLE_IPV6' : (c == 6 ? 'DISABLE_CUSTOM' : 'DEBUG');
                value = c != 7 ? (enabled == '1' ? '0' : '1') : enabled;
            }
            if (c == 3) {
                let mode = choice('Режим фильтрации', ['Все соединения', 'По списку доменов', 'Автоматический список', 'По IP-наборам']);
                if (!mode) return;
                key = 'MODE_FILTER'; value = ['none', 'hostlist', 'autohostlist', 'ipset'][mode - 1];
            }
            if (c == 4 || c == 5) {
                key = 'NFQWS_PORTS_' + (c == 4 ? 'TCP' : 'UDP');
                value = local_file('Порты через запятую; диапазоны через дефис', null);
            }
            command(ctx, ['config', 'set', key, value]);
        });
    }
}

function backup_menu(ctx) {
    while (!ended) {
        let c = choice('Резервные копии Zapret', ['Сохранить настройки', 'Восстановить настройки']);
        if (!c) return;
        perform(() => {
            let file = local_file('Файл резервной копии', ctx.state + '/backups/zapret-backup.json');
            if (c == 1 || confirm('Восстановить настройки из ' + file))
                command(ctx, ['backup', c == 1 ? 'save' : 'restore', file]);
        });
    }
}

function menu(initial, executor) {
    menu_executor = executor;
    let ctx = initial, update_started = false;
    while (!ended) {
        screen('just-zapret-manager ' + VERSION);
        printf('Менеджер: %s\nПоследняя версия менеджера: %s\n', paint('35;1', VERSION), update_status(ctx).label);
        if (!update_started) { start_update_check(ctx); update_started = true; }
        let state = zapret_status(ctx);
        printf('\nZapret: %s\n', state.installed ? paint('32;1', 'установлен · ' + state.version) : paint('31;1', 'не установлен'));
        printf('Сервис: %s\n', paint(state.running ? '32;1' : '33;1', state.running == null ? 'не удалось проверить' : (state.running ? 'запущен' : 'остановлен')));
        printf('%s: %s\n\n', state.running == false ? 'Выбранные стратегии (не запущены)' : 'Стратегии', paint('35', state.strategy));
        let labels = ['Установка / обновление / удаление', 'Запуск и автозапуск', 'Стратегии',
            'Тесты и автоподбор', 'Домены и исключения', 'Настройки Zapret', 'Резервные копии', 'Диагностика и восстановление'];
        for (let i = 0; i < length(labels); i++) menu_line(i + 1, labels[i]);
        menu_line('u', 'Проверить обновления менеджера');
        menu_line('0', 'Выход'); print('\n');
        let value = prompt('Выберите пункт', null);
        if (value == null || value == '' || value == '0') break;
        try {
            switch (lc(value)) {
            case '1': install_menu(ctx); break;
            case '2': service_menu(ctx); break;
            case '3': strategy_menu(ctx); break;
            case '4': test_menu(ctx); break;
            case '5': hosts_menu(ctx); break;
            case '6': config_menu(ctx); break;
            case '7': backup_menu(ctx); break;
            case '8': {
                let c = choice('Диагностика', ['Проверить зависимости и установку', 'Восстановить после аварийного завершения', 'Штатный blockcheck Zapret']);
                if (c) perform(() => command(ctx, [c == 1 ? 'doctor' : (c == 2 ? 'recover' : 'blockcheck')]));
                break;
            }
            case 'u':
                perform(() => {
                    let info = check_update(ctx);
                    printf('Текущая: %s. Последняя: %s\n', VERSION, info.version);
                    if (info.available && confirm('Установить обновление менеджера')) { apply_update(ctx); ended = true; }
                });
                break;
            default: print('Нет такого пункта.\n'); pause();
            }
        }
        catch (e) { printf('\nОшибка: %s\n', e.message); pause(); }
    }
    print('\nДо встречи. Запуск менеджера: jzm\n');
};

// ---- src/lib/commands.uc ----

const HELP = 'Внутренний протокол JZM. Пользовательский запуск: jzm\n';

function arity(args, min, max) {
    check(length(args) >= min && length(args) <= max, 'неверное число аргументов; см. help');
}

function same_content(path, body) {
    let st = fs.stat(path);
    return st != null && st.type == 'file' && st.size == length(body) && fs.readfile(path, st.size + 1) == body;
}

function editable(ctx, key, value) {
    let booleans = ['DISABLE_IPV6', 'DISABLE_CUSTOM', 'ENABLED', 'DEBUG'];
    let ports = ['NFQWS_PORTS_TCP', 'NFQWS_PORTS_UDP'];
    if (index(booleans, key) != -1) check(value == '0' || value == '1', 'ожидается 0 или 1');
    else if (index(ports, key) != -1) {
        for (let range in split(value, ',')) {
            check(match(range, /^[0-9]{1,5}(-[0-9]{1,5})?$/), 'неверный диапазон портов');
            let pair = split(range, '-');
            check(+pair[0] >= 1 && +pair[0] <= 65535 &&
__JZM_JZM_UCODE_5__
)
export JZM_UCODE_5

JZM_UCODE_6=$(cat <<'__JZM_JZM_UCODE_6__'
(length(pair) == 1 || (+pair[1] >= +pair[0] && +pair[1] <= 65535)), 'порт вне диапазона');
        }
    }
    else if (key == 'MODE_FILTER')
        check(index(['none', 'hostlist', 'autohostlist', 'ipset'], value) != -1, 'неверный MODE_FILTER');
    else die('изменение этой опции не поддерживается: ' + key);
}

function dependencies(ctx, body) {
    // The upstream init script expands arguments; paths must exist before config is changed.
    let path_pattern = /^--[^=]+=(\/[^,]+)$/;
    for (let line in split(body, '\n')) {
        let m = match(line, path_pattern);
        if (m) check(fs.stat(ctx.root + m[1])?.type == 'file', 'не найден файл стратегии: ' + m[1]);
    }
}

function persist_applied(ctx, body) {
    let raw = strategy_sections(body);
    let wanted = length(filter(raw, (s) => s.label == null)) ? null : map(raw, (s) => strategy_key(s.label));
    let list = reference_catalog(ctx, wanted);
    let state = create_applied(body, inspect_strategy(body, list), list, time());
    send(ctx, 'state-write', ['state.json'], sprintf('%J\n', state));
}

function approve_strategy_change(ctx) {
    let state = read_applied(ctx);
    if (state == null || strategy_hash(configured_strategy(ctx)) == state.applied_hash) return true;
    print('Внимание: ваши ручные изменения будут заменены версией из каталога. Продолжить? [y/N] ');
    fs.stdout.flush();
    let answer = '';
    while (true) {
        let c = fs.stdin.read(1);
        if (c == null || !length(c)) return false;
        if (c == '\n') break;
        if (c != '\r') answer += c;
        check(length(answer) <= 4096, 'слишком длинное подтверждение');
    }
    return lc(trim(answer)) == 'y';
}

function apply(ctx, body, transient) {
    if (!length(trim(body))) {
        run(ctx, 'config-set', ['NFQWS_OPT', '', 'NFQWS_ENABLE', '0']);
        run(ctx, 'service', ['stop']);
        if (!transient) persist_applied(ctx, '');
        return;
    }
    body = preserve_body(body);
    dependencies(ctx, body);
    let updates = [];
    for (let proto in ['TCP', 'UDP']) {
        let option = 'NFQWS_PORTS_' + proto;
        let ports = trim(output(ctx, 'config-get-optional', [option]));
        let previous = ports;
        let items = length(ports) ? split(ports, ',') : [];
        let filter_pattern = regexp('^--filter-' + lc(proto) + '=([0-9,-]+)$');
        for (let line in split(body, '\n')) {
            let m = match(line, filter_pattern);
            if (m) for (let port in split(m[1], ',')) if (index(items, port) == -1) push(items, port);
        }
        if (length(items)) {
            ports = join(',', items);
            editable(ctx, option, ports);
            if (ports != previous) push(updates, option, ports);
        }
    }
    if (!length(updates) && trim(configured_strategy(ctx)) == trim(body) &&
        replace(output(ctx, 'config-get-optional', ['NFQWS_ENABLE']), /\n$/, '') == '1' && service_running(ctx) == true) {
        if (!transient) persist_applied(ctx, body);
        return;
    }
    run(ctx, 'config-set', [...updates, 'NFQWS_OPT', body, 'NFQWS_ENABLE', '1']);
    run(ctx, 'service', ['restart']);
    if (!transient) persist_applied(ctx, body);
}

function initialize_lists(ctx) {
    for (let kind in ['user', 'exclude', 'google']) {
        let name = kind == 'user' ? 'zapret-hosts-user.txt' :
            (kind == 'exclude' ? 'zapret-hosts-user-exclude.txt' : 'zapret-hosts-google.txt');
        if (fs.stat(ctx.base + '/ipset/' + name)) continue;
        let body = kind == 'google' ? resource(ctx.home, 'google.txt') :
            (kind == 'exclude' ? resource(ctx.home, 'exclude.txt') : '');
        send(ctx, 'hosts-write', [kind], body);
    }
}

function probe(ctx, targets) {
    let ok = 0;
    for (let url in targets) {
        let rc = backend(ctx, 'probe', [ctx.connect_timeout, ctx.request_timeout, url]);
        printf('%s %s\n', rc == 0 ? 'OK' : 'FAIL', url);
        if (rc == 0) ok++;
    }
    return ok;
}

function benchmark(ctx, args, keep, source_kind) {
    arity(args, 1, 2);
    let targets = urls(target_text(ctx, args[0]), ctx.max_urls);
    let list = [], results = [];
    for (let s in catalog(ctx, args[1])) {
        try { dependencies(ctx, s.body); push(list, s); }
        catch (e) { push(results, { name: s.name, skipped: e.message }); }
    }
    check(length(list) > 0, 'нет стратегий с доступными файлами');
    run(ctx, 'service', ['stop']);
    run(ctx, 'settle', [ctx.settle_seconds]);
    let control = probe(ctx, targets), best = null;
    for (let s in list) {
        run(ctx, 'reset-config');
        apply(ctx, label_strategy(s.name, s.body), true);
        run(ctx, 'settle', [ctx.settle_seconds]);
        let score = probe(ctx, targets);
        let row = { name: s.name, ok: score, total: length(targets) };
        push(results, row);
        if (best == null || score > best.ok) best = row;
    }
    run(ctx, 'reset');
    let applied = keep && best.ok > control;
    if (applied) {
        let body = label_strategy(best.name, filter(list, (s) => s.name == best.name)[0].body);
        initialize_lists(ctx);
        if (source_kind != null) prepare_assets(ctx, source_kind, body);
        apply(ctx, body);
    }
    printf('%J\n', { control, total: length(targets), results, best, applied });
}

function host_command(ctx, args) {
    arity(args, 2, ctx.max_domains + 2);
    let kind = args[0], action = args[1], extra = slice(args, 2);
    check(index(['user', 'exclude', 'google'], kind) != -1, 'неверный список доменов');
    if (action == 'show') {
        arity(extra, 0, 0);
        print(output(ctx, 'hosts-read', [kind]));
        return;
    }
    let items;
    if (action == 'replace') {
        arity(extra, 1, 1);
        items = domains(read(extra[0], ctx.max_file_bytes), ctx.max_domains);
    }
    else if (action == 'refresh') {
        arity(extra, 0, 0);
        check(exists(ctx.hostlist_urls, kind), 'URL для списка не задан в manager.json');
        items = domains(output(ctx, 'download', [ctx.connect_timeout, ctx.request_timeout,
                        ctx.max_file_bytes, ctx.hostlist_urls[kind]]), ctx.max_domains);
        check(length(items) > 0, 'сервер вернул пустой список');
    }
    else {
        check(action == 'add' || action == 'remove', 'неизвестная операция со списком');
        arity(extra, 1, ctx.max_domains);
        let old = domains(output(ctx, 'hosts-read', [kind]), ctx.max_domains);
        let change = domains(join('\n', extra), ctx.max_domains);
        items = action == 'add' ? domains(join('\n', [...old, ...change]), ctx.max_domains) :
            filter(old, (name) => index(change, name) == -1);
    }
    let body = length(items) ? join('\n', items) + '\n' : '';
    check(length(body) <= ctx.max_file_bytes, 'список превышает лимит размера');
    send(ctx, 'hosts-write', [kind], body);
    run(ctx, 'service', ['restart']);
}

function backup(ctx, args) {
    arity(args, 2, 2);
    if (args[0] == 'save') {
        let lists = {};
        for (let kind in ['user', 'exclude', 'google']) {
            lists[kind] = output(ctx, 'hosts-read', [kind]);
            validate_list_snapshot(lists[kind], ctx.max_domains, ctx.max_file_bytes);
        }
        let data = { format: 1, profile: ctx.profile, config: read(ctx.config, ctx.max_file_bytes), lists,
                     devices: excluded(ctx), strategy_state: read_applied(ctx) };
        let text = sprintf('%J\n', data);
        check(length(text) <= ctx.max_file_bytes, 'резервная копия превышает max_file_bytes');
        send(ctx, 'backup-write', [args[1]], text);
    }
    else {
        check(args[0] == 'restore', 'backup: save или restore');
        let data = json(read(args[1], ctx.max_file_bytes));
        check(data.format == 1 && data.profile == ctx.profile && type(data.config) == 'string' &&
              type(data.lists) == 'object', 'неверный формат/профиль резервной копии');
        if (data.strategy_state != null) validate_applied(data.strategy_state);
        // Validate the complete document before the first write.
        for (let kind, value in data.lists) {
            check(index(ctx.profile == 'zapret' ? ['user', 'exclude', 'google'] : ['user', 'exclude'], kind) != -1 &&
                  type(value) == 'string', 'неверный список в резервной копии');
            validate_list_snapshot(value, ctx.max_domains, ctx.max_file_bytes);
        }
        if (data.devices != null) {
            check(type(data.devices) == 'array' && length(data.devices) <= 256, 'неверный список устройств в копии');
            for (let ip in data.devices) ipv4(ip);
        }
        let restart = !same_content(ctx.config, data.config);
        for (let kind, value in data.lists) {
            let name = kind == 'user' ? 'zapret-hosts-user.txt' :
                (kind == 'exclude' ? 'zapret-hosts-user-exclude.txt' : 'zapret-hosts-google.txt');
            if (!same_content(ctx.base + '/ipset/' + name, value)) restart = true;
        }
        let hook = data.devices != null ? exclusion_hook(ctx, data.devices) : null;
        let hook_file = ctx.base + '/init.d/openwrt/custom.d/20-jzm-exclude.sh';
        let hook_changed = hook != null && (legacy_exclusions(ctx) != null ||
            !same_content(hook_file, hook) || ((fs.stat(hook_file)?.mode || 0) & 0777) != 0755);
        if (hook_changed) restart = true;
        send(ctx, 'config-restore', [], data.config);
        if (data.strategy_state != null) {
            let saved = sprintf('%J\n', data.strategy_state);
            if (!same_content(ctx.state + '/state.json', saved)) send(ctx, 'state-write', ['state.json'], saved);
        }
        else run(ctx, 'strategy-state-clear');
        for (let kind, value in data.lists) {
            let name = kind == 'user' ? 'zapret-hosts-user.txt' :
                (kind == 'exclude' ? 'zapret-hosts-user-exclude.txt' : 'zapret-hosts-google.txt');
            if (!same_content(ctx.base + '/ipset/' + name, value)) send(ctx, 'hosts-write', [kind], value);
        }
        if (data.devices != null) {
            if (hook_changed) send(ctx, 'device-hook-write', legacy_exclusions(ctx) != null ? ['migrate'] : [], hook);
            let devices_body = length(data.devices) ? join('\n', data.devices) + '\n' : '';
            if (!same_content(ctx.state + '/devices.txt', devices_body)) send(ctx, 'state-write', ['devices.txt'], devices_body);
        }
        if (restart || service_running(ctx) != true) run(ctx, 'service', ['restart']);
    }
}

function dispatch(ctx, command, args) {
    let changes_strategy = (command == 'strategy' && index(['apply', 'import'], args[0]) != -1) ||
        (command == 'source' && index(['apply', 'compose', 'group', 'remove', 'benchmark', 'auto-best'], args[0]) != -1) ||
        command == 'benchmark' || command == 'auto-best';
    // Run after acquiring the transaction lock, before downloads or configuration writes.
    if (changes_strategy && !approve_strategy_change(ctx)) { print('\nДействие отменено.\n'); return; }
    switch (command) {
    case 'uninstall':
        arity(args, 1, 1);
        check(args[0] == 'manager', 'полное удаление выполняется через пакетную фазу');
        run(ctx, 'uninstall-cleanup', args);
        break;
    case 'uninstall-finish':
        arity(args, 1, 1);
        check(args[0] == 'all', 'неверный режим удаления');
        run(ctx, 'uninstall-cleanup', args);
        break;
    case 'manager-install':
        arity(args, 0, 0);
        install_manager(ctx);
        break;
    case 'manager-uninstall':
        arity(args, 0, 0);
        run(ctx, 'manager-uninstall');
        break;
    case 'manager-update':
        arity(args, 0, 0);
        apply_update(ctx);
        break;
    case 'manager-check':
        arity(args, 0, 0);
        check_update(ctx);
        break;
    case 'manager-cache':
        arity(args, 1, 1);
        cache_update(ctx, json(args[0]));
        break;
    case 'network':
        arity(args, 1, 2);
        run(ctx, 'network', args);
        break;
    case 'blockcheck':
        arity(args, 0, 0);
        run(ctx, 'blockcheck');
        break;
    case 'devices': {
        arity(args, 1, 2);
        let current = excluded(ctx);
        if (args[0] == 'list') {
            for (let item in device_list(ctx)) printf('%s %s %s\n', index(current, item.ip) == -1 ? 'Zapret' : 'Исключён', item.ip, item.name);
            break;
        }
        if (args[0] == 'clear') { arity(args, 1, 1); current = []; }
        else {
            check(index(['toggle', 'add', 'remove'], args[0]) != -1, 'неверная команда исключений'); arity(args, 2, 2);
            let ip = ipv4(args[1]);
            let present = index(current, ip) != -1;
            if (args[0] == 'add' && present || args[0] == 'remove' && !present) break;
            if (args[0] == 'add' || args[0] == 'toggle' && !present) push(current, ip);
            else current = filter(current, (item) => item != ip);
        }
        check(fs.stat(ctx.config), 'Zapret не установлен');
        send(ctx, 'device-hook-write', legacy_exclusions(ctx) != null ? ['migrate'] : [], exclusion_hook(ctx, current));
        send(ctx, 'state-write', ['devices.txt'], length(current) ? join('\n', sort(current)) + '\n' : '');
        run(ctx, 'config-set', ['DISABLE_CUSTOM', '0']);
        run(ctx, 'service', ['restart']);
        break;
    }
    case 'package-configure':
        arity(args, 1, 1);
        check(args[0] == 'enable' || args[0] == 'keep', 'неверный режим конфигурации пакета');
        initialize_lists(ctx);
        if (args[0] == 'enable') run(ctx, 'service', ['enable']);
        run(ctx, 'service', ['restart']);
        break;
    case 'source': {
        arity(args, 2, 10);
        let action = args[0], kind = args[1];
        check(kind == 'manager' || kind == 'flowseal', 'неизвестный источник');
        if (action == 'remove') {
            arity(args, kind == 'manager' ? 3 : 2, kind == 'manager' ? 3 : 2);
            let current = output(ctx, 'config-get-optional', ['NFQWS_OPT']);
            apply(ctx, kind == 'manager' ? replace_group(current, '', args[2]) : remove_flowseal(current));
            break;
        }
        if (action == 'refresh') { arity(args, 2, 2); refresh_source(ctx, kind); break; }
        let wanted = index(['show', 'apply', 'compose', 'group'], action) != -1 ?
            map(slice(args, action == 'group' ? 3 : 2), strategy_key) : null;
        let data = source_data(ctx, kind, wanted), list = data.strategies;
        if (action == 'list') { for (let s in list) printf('%s\n', s.name); break; }
        if (action == 'show' || action == 'apply' || action == 'compose' || action == 'group') {
            arity(args, action == 'group' ? 4 : 3, action == 'compose' ? 10 : (action == 'group' ? 4 : 3));
            let selected = [], seen = {};
            for (let name in slice(args, action == 'group' ? 3 : 2)) {
                check(!seen[name], 'повтор стратегии: ' + name);
                seen[name] = true;
                let found = filter(list, (s) => strategy_key(s.name) == strategy_key(name));
                check(length(found) == 1, 'стратегия не найдена: ' + name);
                push(selected, label_strategy(name, found[0].body));
            }
            let body = action == 'compose' ? compose_bodies(selected) : join('--new\n', selected);
            if (action == 'group') body = replace_group(output(ctx, 'config-get-optional', ['NFQWS_OPT']), body, args[2]);
            if (action == 'show') print(body);
            else {
                check(ctx.profile == 'zapret' && fs.stat(ctx.config), 'сначала установите Zapret');
                initialize_lists(ctx);
                prepare_assets(ctx, kind, body, data);
                apply(ctx, body);
            }
            break;
        }
        if (action == 'export') {
            arity(args, 3, 3);
            check(match(args[2], /^[A-Za-z0-9_-]+\.txt$/), 'неверное имя файла каталога');
            send(ctx, 'state-write', [args[2]], data.catalog);
            break;
        }
        check(action == 'benchmark' || action == 'auto-best', 'неизвестное действие источника');
        arity(args, 3, 3);
        initialize_lists(ctx);
        for (let s in list) prepare_assets(ctx, kind, s.body, data);
        let dir = tempdir();
        try { write(dir + '/catalog', data.catalog); benchmark(ctx, [args[2], dir + '/catalog'], action == 'auto-best', kind); }
        catch (e) { fs.unlink(dir + '/catalog'); fs.rmdir(dir); die(e.message); }
        fs.unlink(dir + '/catalog'); fs.rmdir(dir);
        break;
    }
    case 'status': case 'doctor': case 'recover':
        arity(args, 0, 0);
        run(ctx, command);
        break;
    case 'service':
        arity(args, 1, 1);
        check(index(['start', 'stop', 'restart', 'enable', 'disable'], args[0]) != -1, 'неизвестная команда сервиса');
        run(ctx, 'service', args);
        break;
    case 'config':
        arity(args, 1, 3);
        if (args[0] == 'show') { arity(args, 1, 1); print(read(ctx.config, ctx.max_file_bytes)); }
        else if (args[0] == 'get') {
            arity(args, 2, 2);
            check(match(args[1], /^[A-Za-z][A-Za-z0-9_]*$/), 'неверное имя опции');
            print(output(ctx, 'config-get', [args[1]]));
        }
        else {
            check(args[0] == 'set', 'config: show/get/set'); arity(args, 3, 3);
            editable(ctx, args[1], args[2]);
            let current = replace(output(ctx, 'config-get-optional', [args[1]]), /\n$/, '');
            if (current == args[2]) break;
            run(ctx, 'config-set', slice(args, 1));
            run(ctx, 'service', ['restart']);
        }
        break;
    case 'strategy':
        check(length(args) > 0, 'strategy: list/show/apply/import/validate');
        if (args[0] == 'list') {
            arity(args, 1, 2);
            for (let s in catalog(ctx, args[1])) printf('%s\n', s.name);
        }
        else if (args[0] == 'validate' || args[0] == 'import') {
            arity(args, 2, 2);
            let body = preserve_body(read(args[1], ctx.max_file_bytes));
            if (args[0] == 'validate') print(body); else apply(ctx, body);
        }
        else {
            check(args[0] == 'show' || args[0] == 'apply', 'неизвестная операция стратегии');
            arity(args, 2, args[0] == 'show' ? 2 : ctx.max_strategies);
            let body = compose(ctx, slice(args, 1));
            if (args[0] == 'show') print(body); else apply(ctx, body);
        }
        break;
    case 'hosts': host_command(ctx, args); break;
    case 'targets':
        arity(args, 1, 1);
        urls(target_text(ctx, args[0]), ctx.max_urls);
        send(ctx, 'state-write', ['urls.txt'], target_text(ctx, args[0]));
        break;
    case 'backup': backup(ctx, args); break;
    case 'test': {
        arity(args, 1, 1);
        let targets = urls(target_text(ctx, args[0]), ctx.max_urls);
        let ok = probe(ctx, targets);
        printf('%J\n', { ok, total: length(targets) });
        check(ok == length(targets), 'часть URL недоступна');
        break;
    }
    case 'benchmark': case 'auto-best': benchmark(ctx, args, command == 'auto-best'); break;
    case 'schedule':
        arity(args, 1, 3);
        if (args[0] == 'off') arity(args, 1, 1);
        else {
            check(match(args[0], /^([0-9]|1[0-9]|2[0-3])$/), 'час: 0..23');
            arity(args, 2, 3);
            urls(read(args[1], ctx.max_file_bytes), ctx.max_urls);
            if (args[2]) catalog(ctx, args[2]);
        }
        if (args[0] != 'off' && length(args) == 2) {
            send(ctx, 'state-write', ['scheduled.txt'], resource(ctx.home, 'strategies.txt'));
            push(args, ctx.state + '/scheduled.txt');
        }
        run(ctx, 'schedule', [ctx.file, ...args]);
        break;
    default: die('неизвестная команда: ' + command);
    }
}

function package_phase(ctx, command, args) {
    check(!getenv('ZM_TRANSACTION'), 'пакетная операция внутри транзакции запрещена');
    let mode = null;
    if (command == 'install-upstream' || command == 'update-upstream') {
        arity(args, 0, 0);
        if (release_install(ctx) == 'both') mode = 'enable';
    }
    else {
        if (command == 'remove') arity(args, 0, 0);
        for (let file in args) {
            check(match(fs.basename(file), /^(luci-app-)?zapret[_-][A-Za-z0-9_.+-]+\.(ipk|apk)$/), 'ожидается локальный пакет Zapret: ' + file);
            check(fs.stat(file)?.type == 'file', 'пакет не найден: ' + file);
        }
        let before = package_versions(ctx).zapret;
        run(ctx, 'package', [command, ...args]);
        let after = package_versions(ctx).zapret;
        if (command != 'remove' && after && after != before) mode = before ? 'keep' : 'enable';
    }
    if (mode == null) return 0;
    let argv = [...(fs.stat(ctx.file) ? ['--config', ctx.file] : []), 'package-configure', mode];
    return backend(ctx, 'transaction', argv) == 0 ? 0 : 1;
}

function command_main(argv) {
try {
    // ucode defers handlers until a synchronous helper has finished. The supervisor
    // waits for that worker before restoring files, so helpers cannot race the rollback.
    for (let name in ['SIGINT', 'SIGTERM', 'SIGHUP'])
        signal(name, () => die('операция прервана'));
    let args = [...argv], file = null;
    while (length(args) && substr(args[0], 0, 2) == '--') {
        let flag = shift(args);
        if (flag == '--help') { print(HELP); return 0; }
        check(flag == '--config', 'неизвестный параметр: ' + flag);
        check(length(args), 'не задано значение ' + flag);
        file = shift(args);
    }
    let command = shift(args) || 'help';
    if (command == 'help') { print(HELP); return 0; }
    if (command == 'version') { print(VERSION + '\n'); return 0; }
    let ctx = settings(getenv('ZM_HOME'), file);
    if ((command == 'manager-install' || command == 'manager-uninstall' || command == 'uninstall') && getenv('DESTDIR')) {
        let destination = getenv('DESTDIR');
        check(match(destination, /^\/[A-Za-z0-9_./ -]+$/) && !match(destination, /(^|\/)\.\.?(\/|$)/), 'неверный DESTDIR');
        ctx.root = destination == '/' ? '' : replace(destination, /\/$/, '');
        ctx.state = ctx.root + '/etc/zapret-manager';
        ctx.base = ctx.root + '/opt/zapret';
        ctx.config = ctx.root + '/etc/config/zapret';
    }
    if (command == 'uninstall') {
        arity(args, 1, 1);
        check(index(['manager', 'all'], args[0]) != -1, 'ожидается manager или all');
        if (args[0] == 'all') {
            check(!getenv('ZM_TRANSACTION'), 'пакетная операция внутри транзакции запрещена');
            check(!fs.stat(ctx.root + '/tmp/zapret-manager.zapret.lock'), 'занято: выполняется другая операция');
            run(ctx, 'package', ['remove']);
__JZM_JZM_UCODE_6__
)
export JZM_UCODE_6

JZM_UCODE_7=$(cat <<'__JZM_JZM_UCODE_7__'
return backend(ctx, 'transaction', [...(fs.stat(ctx.file) ? ['--config', ctx.file] : []), 'uninstall-finish', 'all']) == 0 ? 0 : 1;
        }
    }
    if (command == 'uninstall-finish') check(getenv('ZM_TRANSACTION'), 'внутренняя команда транзакции');
    if (index(['install', 'update', 'remove', 'install-upstream', 'update-upstream'], command) != -1)
        return package_phase(ctx, command, args);
    // Pure input errors need neither a snapshot nor a worker; validate again under the lock.
    if (command == 'config' && args[0] == 'set') {
        arity(args, 3, 3);
        editable(ctx, args[1], args[2]);
    }
    let readonly = index(['status', 'doctor', 'test', 'recover', 'blockcheck', 'manager-check'], command) != -1 ||
        (command == 'network' && args[0] == 'status') ||
        (command == 'devices' && args[0] == 'list') ||
        (command == 'source' && index(['list', 'show'], args[0]) != -1) ||
        (command == 'strategy' && index(['list', 'show', 'validate'], args[0]) != -1) ||
        (command == 'config' && index(['show', 'get'], args[0]) != -1) ||
        (command == 'hosts' && args[1] == 'show');
    if (!readonly && !getenv('ZM_TRANSACTION')) {
        // A POSIX supervisor owns the lock, signal handling and rollback for the entire command.
        let rc = backend(ctx, 'transaction', argv);
        return rc == 0 ? 0 : 1;
    }
    dispatch(ctx, command, args);
    return 0;
}
catch (e) {
    warn('zapret-manager: ' + e.message + '\n');
    return 1;
}
};

// ---- src/main.uc ----

try {
    if (getenv('JZM_MODE') == 'command') exit(command_main(ARGV));
    check(!length(ARGV), 'Запустите менеджер без аргументов: jzm');
    menu(settings(getenv('ZM_HOME'), getenv('JZM_CONFIG')), command_main);
}
catch (e) {
    warn('jzm: ' + e.message + '\n');
    exit(1);
}
__JZM_JZM_UCODE_7__
)
export JZM_UCODE_7

JZM_PARTS=7
export JZM_PARTS
# Source is compiled in memory. Separate environment values stay below Linux's
# per-argument limit; stdin remains available to the terminal menu and blockcheck.
# This value is ucode source passed as one interpreter argument.
# shellcheck disable=SC2089
JZM_BOOTSTRAP='let source = ""; for (let i = 1; i <= +getenv("JZM_PARTS"); i++) source += getenv("JZM_UCODE_" + i) + "\n"; loadstring(source, { strict_declarations: true })();'
ZM_HOME=${ZM_HOME:-/}
# shellcheck disable=SC2090
export JZM_BOOTSTRAP ZM_HOME
exec ucode -S -e "$JZM_BOOTSTRAP" -- "$@"
