#!/bin/sh
set -eu
project=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd)
cd "$project"
sdk=${JZM_DEV_HOME:-$HOME/.local/share/jzm-dev}
mkdir -p .test-tmp/dev
for variant in openwrt-24.10 openwrt-25.12 upstream; do
    printf 'Матрица: %s\n' "$variant"
    sh tools/setup-dev.sh "$variant" > ".test-tmp/dev/setup-$variant.log" 2>&1 || {
        cat ".test-tmp/dev/setup-$variant.log" >&2; exit 1;
    }
    if PATH="$sdk/$variant/bin:$PATH" JZM_TEST_BUNDLE=1 just bundle \
        > ".test-tmp/dev/verify-$variant.log" 2>&1; then
        printf 'PASS: %s (лог: .test-tmp/dev/verify-%s.log)\n' "$variant" "$variant"
    else
        cat ".test-tmp/dev/verify-$variant.log" >&2
        exit 1
    fi
done
