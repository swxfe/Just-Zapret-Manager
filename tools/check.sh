#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
command -v ucode >/dev/null 2>&1 || { printf '%s\n' 'check: нужен ucode' >&2; exit 1; }
command -v shellcheck >/dev/null 2>&1 || { printf '%s\n' 'check: нужен shellcheck' >&2; exit 1; }
find src tools tests -type f -name '*.sh' -print | while IFS= read -r file; do
    sh -n "$file"
    case "$file" in
        tests/integration/cases/*|tests/setup/integration.sh|tests/setup/packages.sh|tests/setup/safety.sh|tests/setup/uninstall.sh|tests/setup/emulator.sh|tests/e2e/router/*)
            # These fragments are analyzed through the runner or assembled guest payload below.
            ;;
        *) shellcheck --external-sources --check-sourced --shell=sh "$file";;
    esac
done
for payload in bootstrap router; do
    sh tests/e2e/run.sh payload "$payload" | sh -n
    sh tests/e2e/run.sh payload "$payload" | shellcheck --shell=sh -
done
project=$(pwd -P)
# Entry programs import the unit/setup/support modules too. Stable ucode lacks -cmodule.
for file in src/main.uc tests/unit/run.uc tests/integration/*.uc tests/performance/*.uc tests/http/*.uc tests/mocks/*.uc tools/*.uc; do
    ucode -S -L "$project/src/lib" -c -o /dev/null "$file"
done
python3 - <<'PY'
import ast
from pathlib import Path
for path in [*Path('tests').rglob('*.py'), *Path('tools').rglob('*.py')]:
    ast.parse(path.read_text(), filename=str(path))
PY
JZM_MODE='command' sh src/launcher.sh strategy list tests/fixtures/strategies.txt >/dev/null
# No legacy installer or downloaded-and-executed shell is allowed back into runtime.
if grep -Ein 'mihomo|magitrickle|netshift|byedpi|tg-ws|amnezia|steer|splify|curl.*\|.*sh|wget.*\|.*sh' \
    src/launcher.sh src/shell/*.sh src/lib/*.uc src/main.uc data/*.json; then
    printf '%s\n' 'check: найден посторонний компонент' >&2
    exit 1
fi
printf '%s\n' 'check: OK'
