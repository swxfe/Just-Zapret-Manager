#!/bin/sh
set -eu
setup_emulator() {
    emulator=$project/.emulator
    version=${E2E_OPENWRT_VERSION:-25.12.5}
    fail() { printf 'emulator-setup: %s\n' "$*" >&2; exit 1; }
    need() { command -v "$1" >/dev/null 2>&1 || fail "нужна команда $1 (см. readme.md)"; }
    [ "$(uname -s):$(uname -m)" = Linux:x86_64 ] || fail 'нужен Linux x86_64 или WSL2; Git Bash не запускает Linux QEMU'
    case "$version" in ''|*[!0-9.]*|.*|*..*|*.) fail 'E2E_OPENWRT_VERSION: укажите точный релиз, например 25.12.5';; esac
    need python3
    need bash
    mkdir -p "$emulator"
    lock=$emulator/.setup.lock
    mkdir "$lock" 2>/dev/null || fail "подготовка уже идёт: $lock"
    trap 'rc=$?; trap - 0 INT TERM HUP; rmdir "$lock" 2>/dev/null || :; exit "$rc"' 0
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    if [ ! -x "$emulator/qemu/qemu-system-aarch64" ] ||
       [ ! -f "$emulator/tools/prepare-nand.sh" ] ||
       [ ! -f "$emulator/presets/cudy-wr3000p-v1.ini" ] ||
       [ ! -f "$emulator/.jzm-release.json" ]; then
        host_python assets "$emulator"
    else
        printf '%s\n' 'Router Emulator: используется локальная установка, загрузка не нужна.'
    fi
    image=$emulator/images/$version/nand-wr3000p
    ready=yes
    [ -f "$image/.jzm-ready" ] || ready=no
    for part in 0.BL2 1.u-boot-env 2.Factory 3.bdinfo 4.FIP 5.ubi; do
        [ -s "$image/mt7981.mtd$part.bin" ] || ready=no
    done
    if [ "$ready" = yes ]; then
        printf 'OpenWrt %s: готовый чистый образ %s\n' "$version" "$image"
        exit 0
    fi
    need wget
    need sha256sum
    if ! command -v ubinize >/dev/null 2>&1 && [ ! -x /usr/sbin/ubinize ] && [ ! -x /sbin/ubinize ]; then
        fail 'нужен ubinize из mtd-utils'
    fi
    mkdir -p "$(dirname "$image")"
    rm -f "$image/.jzm-ready"
    # Release packages omit the QEMU source chip table: pass the preset's geometry explicitly.
    bash "$emulator/tools/prepare-nand.sh" --flash-type nand --flash-id c8017f7f7f --flash-mb 128 \
        cudy_wr3000p-v1 "$version" "$image" </dev/null
    for part in 0.BL2 1.u-boot-env 2.Factory 3.bdinfo 4.FIP 5.ubi; do
        [ -s "$image/mt7981.mtd$part.bin" ] || fail "неполный образ: mtd$part"
    done
    printf '%s\n' "$version" > "$image/.jzm-ready"
    printf 'Готово: Cudy WR3000P v1 / OpenWrt %s\n' "$version"
}
