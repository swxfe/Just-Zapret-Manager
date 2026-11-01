#!/bin/sh
set -eu
# Upstream catalogs are parsed as data, stored atomically and applied with required resources.
touch "$ZM_TEST_ROOT/mock-sources"
cli source refresh manager > "$work/source.out"
cli source list manager | grep -q '^v99$'
cli source refresh flowseal > "$work/source.out"
cli source list flowseal | grep -q '^general$'
# API failures must explain themselves and preserve catalogs, UCI and service state.
cp "$ZM_TEST_ROOT/etc/zapret-manager/manager.json" "$work/api-manager.before"
cp "$ZM_TEST_ROOT/etc/zapret-manager/flowseal.json" "$work/api-flowseal.before"
cp "$conf" "$work/api-conf.before"
for kind in primary secondary throttled forbidden unavailable transport; do
    printf '403\n' > "$ZM_TEST_ROOT/api-status"
    printf '59\n' > "$ZM_TEST_ROOT/api-remaining"
    printf '{"message":"Resource not accessible"}' > "$ZM_TEST_ROOT/api-body"
    case "$kind" in
        primary) printf '0\n' > "$ZM_TEST_ROOT/api-remaining";;
        secondary) printf '{"message":"You have exceeded a secondary rate limit."}' > "$ZM_TEST_ROOT/api-body";;
        throttled) printf '429\n' > "$ZM_TEST_ROOT/api-status";;
        unavailable) printf '503\n' > "$ZM_TEST_ROOT/api-status"; printf '<html>Unavailable</html>' > "$ZM_TEST_ROOT/api-body";;
        transport) touch "$ZM_TEST_ROOT/api-transport-fail";;
    esac
    for command in 'source refresh manager' 'source refresh flowseal' 'install-upstream'; do
        # These fixed test commands deliberately expand into separate arguments.
        # shellcheck disable=SC2086
        bad cli $command
        case "$kind" in
            primary|secondary|throttled) grep -Fq 'Превышен лимит запросов GitHub API (60/час на ваш IP)' "$work/error";;
            forbidden) grep -Fq 'GitHub API: ошибка HTTP 403' "$work/error";;
            unavailable) grep -Fq 'GitHub API: ошибка HTTP 503' "$work/error";;
            transport) grep -Fq 'github-download: код завершения 28' "$work/error";;
        esac
        equal_file "$conf" "$work/api-conf.before"
        equal_file "$ZM_TEST_ROOT/etc/zapret-manager/manager.json" "$work/api-manager.before"
        equal_file "$ZM_TEST_ROOT/etc/zapret-manager/flowseal.json" "$work/api-flowseal.before"
        cli status | grep -q running
        [ ! -d "$ZM_TEST_ROOT/tmp/zapret-manager.zapret.lock" ]
    done
done
rm -f "$ZM_TEST_ROOT/api-status" "$ZM_TEST_ROOT/api-remaining" "$ZM_TEST_ROOT/api-body" "$ZM_TEST_ROOT/api-transport-fail"
printf '%s\n' 'sources: 18 API failures preserve catalogs, configuration and service state'
