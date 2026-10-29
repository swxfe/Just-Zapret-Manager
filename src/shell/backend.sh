#!/bin/sh
# shellcheck source=src/shell/common.sh
. "$(dirname "$0")/common.sh"

case "$action" in
uninstall-cleanup)
    exec /bin/sh "$(dirname "$0")/uninstall.sh" "$action" "$root" "$profile" "$@"
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
    exec /bin/sh "$(dirname "$0")/network.sh" "$action" "$root" "$profile" "$@"
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
    exec /bin/sh "$(dirname "$0")/packages.sh" "$action" "$root" "$profile" "$@"
    ;;
transaction|recover|reset-config|reset|blockcheck)
    exec /bin/sh "$(dirname "$0")/transaction.sh" "$action" "$root" "$profile" "$@"
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
    exec /bin/sh "$(dirname "$0")/packages.sh" "$action" "$root" "$profile" "$@"
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
