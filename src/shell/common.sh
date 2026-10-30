#!/bin/sh
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
