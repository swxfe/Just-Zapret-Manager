#!/bin/sh
set -eu
[ "${JZM_E2E_GUEST:-}" = 1 ] && [ -f /etc/openwrt_release ] || exit 2
ubus call system board > /tmp/jzm-e2e-board.json
grep -q 'cudy,wr3000p-v1' /tmp/jzm-e2e-board.json
retry() {
    attempt=0
    until "$@"; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 3 ] || return 1
        sleep 2
    done
}
if command -v apk >/dev/null 2>&1; then
    retry apk update
    retry apk add ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus ucode-mod-digest ucode-mod-uclient ucode-mod-uloop curl ca-bundle unzip
else
    retry opkg update
    retry opkg install ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus ucode-mod-digest ucode-mod-uclient ucode-mod-uloop curl ca-bundle unzip
fi
ucode -S -e 'import * as fs from "fs"; assert(fs.stat("/etc/openwrt_release") != null);'
mkdir -p /tmp/jzm-e2e
printf '%s\n' 'Cudy WR3000P / isolated JZM E2E' > /tmp/jzm-e2e/guard
