#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
command -v ucode >/dev/null 2>&1 || { printf '%s\n' 'check: нужен ucode' >&2; exit 1; }
command -v shellcheck >/dev/null 2>&1 || { printf '%s\n' 'check: нужен shellcheck' >&2; exit 1; }
for file in src/launcher.sh src/shell/*.sh tools/*.sh tests/*.sh; do
    sh -n "$file"
    shellcheck --external-sources --shell=sh "$file"
done
for payload in bootstrap router; do
    sh tests/e2e-emulator.sh payload "$payload" | sh -n
    sh tests/e2e-emulator.sh payload "$payload" | shellcheck --shell=sh -
done
project=$(pwd -P)
# Entry programs import every library, so compilation checks the modules too.
# -cmodule is unavailable in the ucode packages shipped with stable OpenWrt.
for file in src/main.uc tests/*.uc tools/*.uc; do
    ucode -S -L "$project/src/lib" -c -o /dev/null "$file"
done
JZM_MODE='command' sh src/launcher.sh strategy list >/dev/null
# No legacy installer or downloaded-and-executed shell is allowed back into runtime.
if grep -Ein 'mihomo|magitrickle|netshift|byedpi|tg-ws|amnezia|steer|splify|curl.*\|.*sh|wget.*\|.*sh' \
    src/launcher.sh src/shell/*.sh src/lib/*.uc src/main.uc data/*.json; then
    printf '%s\n' 'check: найден посторонний компонент' >&2
    exit 1
fi
printf '%s\n' 'check: OK'
