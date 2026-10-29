#!/bin/sh
# JZM_VERSION=@VERSION@
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
