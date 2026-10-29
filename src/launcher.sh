#!/bin/sh
set -eu
[ "${JZM_MODE:-}" = command ] || [ "$#" -eq 0 ] || { printf '%s\n' 'Запустите менеджер без аргументов: jzm' >&2; exit 2; }

ZM_HOME=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd)
export ZM_HOME
if ! command -v ucode >/dev/null 2>&1; then
    printf '%s\n' 'zapret-manager: требуется ucode и модуль ucode-mod-fs' >&2
    exit 127
fi
exec ucode -S -L "$ZM_HOME/src/lib" -- "$ZM_HOME/src/main.uc" "$@"
