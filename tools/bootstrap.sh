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
   ! ucode -S -e 'import * as fs from "fs"; import * as uci from "uci"; import * as ubus from "ubus"; import * as digest from "digest"; import * as uclient from "uclient"; import * as uloop from "uloop";' >/dev/null 2>&1; then
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
        apk add ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus ucode-mod-digest ucode-mod-uclient ucode-mod-uloop uci curl ca-bundle unzip
    elif command -v opkg >/dev/null 2>&1; then
        opkg update
        opkg install ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus ucode-mod-digest ucode-mod-uclient ucode-mod-uloop uci curl ca-bundle unzip
    else
        printf '%s\n' 'Не найден пакетный менеджер apk/opkg.' >&2; exit 1
    fi
fi

work=$(mktemp -d /tmp/jzm-install.XXXXXX)
trap 'rm -rf -- "$work"' 0
trap 'exit 130' INT
trap 'exit 143' TERM HUP
download() {
    curl --fail --silent --show-error --location --max-redirs 3 --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 120 --max-filesize "$3" --output "$2" "$1"
}
target_dir=/overlay
[ -d "$target_dir" ] || target_dir=/
available=$(df -Pk "$target_dir" | awk 'NR==2 {print $4}')
case "$available" in ''|*[!0-9]*) printf '%s\n' 'Не удалось проверить свободное место.' >&2; exit 1;; esac
[ "$available" -ge 5120 ] || { printf '%s\n' 'Недостаточно свободного места: требуется резерв 5120 KB.' >&2; exit 1; }
# A commit SHA keeps the code and resource archive from different revisions apart.
download https://api.github.com/repos/swxfe/just-zapret-manager/commits/main "$work/revision.json" 65536
revision=$(ucode -S -e 'import * as fs from "fs"; let sha=json(fs.readfile(ARGV[0])).sha; if(type(sha)!="string" || !match(sha,/^[a-f0-9]{40}$/)) exit(1); print(sha);' "$work/revision.json")
base=https://raw.githubusercontent.com/swxfe/just-zapret-manager/$revision/dist
# Obtain payload sizes before pulling binaries; unknown sizes use conservative bounds.
payload_size() {
    curl --fail --silent --show-error --location --head --max-redirs 3 --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 60 --output "$work/headers" "$1"
    size=$(awk 'tolower($1)=="content-length:" {gsub("\r", "", $2); value=$2} END {print value}' "$work/headers")
    case "$size" in ''|*[!0-9]*) size=$2;; esac
    [ "${#size}" -le 8 ] && [ "$size" -gt 0 ] && [ "$size" -le "$2" ] || size=$2
    printf '%s\n' "$size"
}
code_size=$(payload_size "$base/Zapret-Manager.sh" 2097152)
asset_size=$(payload_size "$base/jzm-assets.tar.gz" 8388608)
required=$(( ((code_size + asset_size + 1023) / 1024) * 2 + 5120 ))
[ "$available" -ge "$required" ] || { printf '%s\n' 'Недостаточно места для JZM, ассетов и резерва Flash.' >&2; exit 1; }
download "$base/Zapret-Manager.sh" "$work/manager.sh" 2097152
download "$base/jzm-assets.tar.gz" "$work/jzm-assets.tar.gz" 8388608
test -s "$work/manager.sh"
test -s "$work/jzm-assets.tar.gz"
sh -n "$work/manager.sh"
# Expanded-size preflight and validation run before any managed asset is written.
JZM_MODE='command' sh "$work/manager.sh" manager-install "$work/jzm-assets.tar.gz"
rm -rf -- "$work"
trap - 0 INT TERM HUP
exec /usr/bin/jzm
