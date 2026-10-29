#!/bin/sh
set -eu
umask 077

[ "$#" -eq 0 ] || { printf '%s\n' 'Запустите установщик без аргументов.' >&2; exit 2; }
[ "$(id -u)" = 0 ] && [ -f /etc/openwrt_release ] || {
    printf '%s\n' 'Установщик предназначен для OpenWrt. Запустите его от root по SSH.' >&2
    exit 1
}

if ! command -v curl >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1 ||
   ! command -v uci >/dev/null 2>&1 ||
   ! ucode -S -e 'import * as fs from "fs";' >/dev/null 2>&1; then
    target_dir=/overlay
    [ -d "$target_dir" ] || target_dir=/
    available=$(df -Pk "$target_dir" | awk 'NR==2 {print $4}')
    case "$available" in ''|*[!0-9]*) printf '%s\n' 'Не удалось проверить свободное место.' >&2; exit 1;; esac
    # Conservative allowance for the runtime and HTTPS dependencies, plus flash reserve.
    dependency_kb=8192
    [ "$available" -ge "$((dependency_kb * 2 + 5120))" ] || {
        printf '%s\n' 'Недостаточно места для зависимостей и безопасного резерва Flash.' >&2; exit 1;
    }
    if command -v apk >/dev/null 2>&1; then
        apk update
        apk add ucode ucode-mod-fs uci curl ca-bundle unzip
    elif command -v opkg >/dev/null 2>&1; then
        opkg update
        opkg install ucode ucode-mod-fs uci curl ca-bundle unzip
    else
        printf '%s\n' 'Не найден пакетный менеджер apk/opkg.' >&2; exit 1
    fi
fi

work=$(mktemp -d /tmp/jzm-install.XXXXXX)
trap 'rm -rf -- "$work"' 0
trap 'exit 130' INT
trap 'exit 143' TERM HUP
curl --fail --silent --show-error --location --max-redirs 3 --proto '=https' --proto-redir '=https' \
    --connect-timeout 10 --max-time 120 --max-filesize 2097152 \
    --output "$work/manager.sh" \
    https://raw.githubusercontent.com/swxfe/just-zapret-manager/main/dist/just-zapret-manager.sh
test -s "$work/manager.sh"
sh -n "$work/manager.sh"
JZM_MODE='command' sh "$work/manager.sh" manager-install
rm -rf -- "$work"
trap - 0 INT TERM HUP
exec /usr/bin/jzm
