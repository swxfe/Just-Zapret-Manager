#!/bin/sh
set -eu
out='' url='' headers='' code='200' writeout=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) out=$2; shift 2;;
        --dump-header) headers=$2; shift 2;;
        --write-out) writeout=$2; shift 2;;
        --connect-timeout|--max-time|--max-filesize|--max-redirs|--proto|--proto-redir) shift 2;;
        --*) shift;;
        *) url=$1; shift;;
    esac
done
if [ -n "$headers" ]; then
    if [ -f "$ZM_TEST_ROOT/api-status" ]; then code=$(cat "$ZM_TEST_ROOT/api-status"); fi
    printf 'HTTP/2 %s\r\n' "$code" > "$headers"
    if [ -f "$ZM_TEST_ROOT/api-remaining" ]; then
        printf 'X-RateLimit-Remaining: %s\r\n' "$(cat "$ZM_TEST_ROOT/api-remaining")" >> "$headers"
    fi
    if [ -n "$writeout" ]; then printf '%s' "$code"; fi
    if [ -f "$ZM_TEST_ROOT/api-transport-fail" ]; then exit 28; fi
    if [ -f "$ZM_TEST_ROOT/api-body" ]; then cat "$ZM_TEST_ROOT/api-body" > "$out"; exit 0; fi
fi
if [ -f "$ZM_TEST_ROOT/mock-release" ]; then
    case "$url" in
        https://api.github.com/repos/remittor/zapret-openwrt/releases/latest)
            printf '{"tag_name":"v72.20260307","assets":[]}' > "$out"
            exit 0;;
    esac
fi
case "$url" in
    https://api.github.com/repos/jzm-fixture/manager/commits/main)
        [ ! -f "$ZM_TEST_ROOT/update-offline" ] || exit 22
        printf '{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
        exit 0;;
    https://raw.githubusercontent.com/jzm-fixture/manager/*/dist/just-zapret-manager.sh)
        [ ! -f "$ZM_TEST_ROOT/update-offline" ] || exit 22
        cat "$ZM_TEST_ROOT/manager-release"
        exit 0;;
esac
if [ -f "$ZM_TEST_ROOT/pause-probe" ]; then
    : > "$ZM_TEST_ROOT/probe-entered"
    sleep 2
    rm -f "$ZM_TEST_ROOT/pause-probe"
fi
if [ "$out" != /dev/null ]; then
    if [ -f "$ZM_TEST_ROOT/mock-sources" ]; then
        case "$url" in
            https://api.github.com/repos/*/commits/*) printf '{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' > "$out"; exit 0;;
            */Zapret-Manager.sh) cat "$ZM_HOME/tests/fixtures/manager.txt" > "$out"; exit 0;;
            */files/StrYoutube) cat "$ZM_HOME/tests/fixtures/youtube.txt" > "$out"; exit 0;;
            */git/trees/*) printf '{"tree":[{"type":"blob","path":"general.bat"}],"truncated":false}' > "$out"; exit 0;;
            */general.bat) cat "$ZM_HOME/tests/fixtures/flowseal.bat" > "$out"; exit 0;;
            */bin/*.bin) printf 'FAKE-BLOB-FIXTURE' > "$out"; exit 0;;
        esac
    fi
    cat "$ZM_TEST_ROOT/download" > "$out"
    exit 0
fi
[ -f "$ZM_TEST_ROOT/state" ] || exit 22
opts=$(uci -c "$ZM_TEST_ROOT/etc/config" -q get 'zapret.@main[0].NFQWS_OPT')
case "$opts:$url" in
    *multisplit:*) exit 0;;
    *fake:https://one.test/*) exit 0;;
    *) exit 22;;
esac
