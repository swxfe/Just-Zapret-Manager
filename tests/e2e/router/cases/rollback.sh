#!/bin/sh
set -eu
busy_lock() {
    cp "$conf" "$root/before"
    mkdir "$lock"
    printf '%s\n' "$$" > "$lock/pid"
    trap 'rm -f "$lock/pid"; rmdir "$lock"' 0
    reject jzm config set DISABLE_IPV6 1
    reject jzm recover
    cmp "$root/before" "$conf"
    health
}
failed_download() {
    cp /etc/zapret-manager/manager.json "$root/cache-before"
    cp "$conf" "$root/before"
    mkdir -p "$root/fail-bin"
    printf 'function request(url, options) { die("HTTP transport failure"); }; return {request};\n' > "$root/fail-http.uc"
    printf '#!/bin/sh\nexit 22\n' > "$root/fail-bin/curl"
    chmod 755 "$root/fail-bin/curl"
    reject env JZM_HTTP_PROVIDER="$root/fail-http.uc" PATH="$root/fail-bin:$PATH" JZM_MODE=command /usr/bin/jzm source refresh manager
    cmp "$root/cache-before" /etc/zapret-manager/manager.json
    unchanged
}
github_rate_limit() {
    cp /etc/zapret-manager/manager.json "$root/cache-before"
    cp "$conf" "$root/before"
    mkdir -p "$root/rate-bin"
    cat > "$root/rate-bin/curl" <<'EOF'
#!/bin/sh
set -eu
out='' headers=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) out=$2; shift 2;;
        --dump-header) headers=$2; shift 2;;
        *) shift;;
    esac
done
[ -n "$out" ] && [ -n "$headers" ]
printf 'HTTP/2 403\r\nX-RateLimit-Remaining: 0\r\n\r\n' > "$headers"
printf '{"message":"API rate limit exceeded for IP"}' > "$out"
printf '403'
EOF
    printf '%s\n' 'function request(url, options) { return {status:403,headers:{"x-ratelimit-remaining":"0"},body:"API rate limit exceeded for IP"}; }; return {request};' > "$root/rate-http.uc"
    chmod 755 "$root/rate-bin/curl"
    for operation in source install; do
        if [ "$operation" = source ]; then set -- source refresh manager; else set -- install-upstream; fi
        reject env JZM_HTTP_PROVIDER="$root/rate-http.uc" PATH="$root/rate-bin:$PATH" JZM_MODE=command /usr/bin/jzm "$@" > "$root/api-error" 2>&1
        grep -Fq 'Превышен лимит запросов GitHub API (60/час на ваш IP)' "$root/api-error"
        cmp "$root/cache-before" /etc/zapret-manager/manager.json
        unchanged
    done
}
blockcheck_restore() {
    cp "$conf" "$root/before"
    cp /etc/zapret-manager/state.json "$root/blockcheck-state"
    cp -p /opt/zapret/blockcheck.sh "$root/blockcheck.original"
    trap 'cp -p "$root/blockcheck.original" /opt/zapret/.blockcheck.restore; mv -f /opt/zapret/.blockcheck.restore /opt/zapret/blockcheck.sh' 0
    cat > /opt/zapret/.blockcheck.test <<'EOF'
#!/bin/sh
set -eu
if /etc/init.d/zapret running; then exit 90; fi
printf 'blockcheck ready\n'
IFS= read -r answer
[ "$answer" = ready ]
case "$(cat /tmp/jzm-e2e/blockcheck-mode)" in
    success) :;;
    failure) exit 23;;
    INT) kill -INT "$PPID"; exit 130;;
    TERM) kill -TERM "$PPID"; exit 143;;
    HUP) kill -HUP "$PPID"; exit 143;;
    *) exit 2;;
esac
EOF
    mv -f /opt/zapret/.blockcheck.test /opt/zapret/blockcheck.sh
    for mode in success failure INT TERM HUP; do
        printf '%s\n' "$mode" > "$root/blockcheck-mode"
        if [ "$mode" = success ]; then
            printf 'ready\n' | jzm blockcheck > "$root/blockcheck-output" 2>&1
        else
            printf 'ready\n' | reject jzm blockcheck > "$root/blockcheck-output" 2>&1
        fi
        grep -q 'blockcheck ready' "$root/blockcheck-output"
        cmp "$root/blockcheck-state" /etc/zapret-manager/state.json
        unchanged
    done
    jzm service stop
    jzm service disable
    printf 'success\n' > "$root/blockcheck-mode"
    printf 'ready\n' | jzm blockcheck
    reject /etc/init.d/zapret running
    reject /etc/init.d/zapret enabled
    reject nfqws_pids
    cmp "$root/before" "$conf"
    [ ! -d "$lock" ]
    jzm service enable
    jzm service start
    health
}
rollback_after_write() {
    cp "$conf" "$root/before"
    cp -p /opt/zapret/sync_config.sh "$root/sync.original"
    trap 'cp -p "$root/sync.original" /opt/zapret/sync_config.sh; rm -f "$root/fail-sync"' 0
    {
        printf '#!/bin/sh\n'
        printf 'if [ -f /tmp/jzm-e2e/fail-sync ]; then\n'
        printf '  uci get "zapret.@main[0].DISABLE_IPV6" > /tmp/jzm-e2e/observed-write\n'
        printf '  rm /tmp/jzm-e2e/fail-sync\n  exit 97\nfi\n'
        cat "$root/sync.original"
    } > "$root/sync.injected"
    cp "$root/sync.injected" /opt/zapret/sync_config.sh
    old=$(jzm config get DISABLE_IPV6)
    changed=$((1 - old))
    touch "$root/fail-sync"
    reject jzm config set DISABLE_IPV6 "$changed"
    [ "$(cat "$root/observed-write")" = "$changed" ]
    unchanged
}
interrupted_transaction() {
    cp "$conf" "$root/before"
    mkdir -p "$root/slow-bin"
    cat > "$root/slow-bin/curl" <<'EOF'
#!/bin/sh
touch /tmp/jzm-e2e/probe-entered
sleep 3
exit 22
EOF
    printf '%s\n' 'import * as fs from "fs"; function request(url, options) { fs.writefile("/tmp/jzm-e2e/probe-entered","1"); sleep(3000); return {status:503,headers:{},body:""}; }; return {request};' > "$root/slow-http.uc"
    chmod 755 "$root/slow-bin/curl"
    printf '%s\n' '#probe' '--filter-tcp=443' '--dpi-desync=multisplit' > "$root/probe-catalog.txt"
    printf '%s\n' 'http://127.0.0.1/' > "$root/targets.txt"
    env JZM_HTTP_PROVIDER="$root/slow-http.uc" PATH="$root/slow-bin:$PATH" JZM_MODE=command /usr/bin/jzm benchmark "$root/targets.txt" "$root/probe-catalog.txt" &
    job=$!
    trap 'kill -TERM "$job" 2>/dev/null || :; wait "$job" 2>/dev/null || :' 0
    attempts=0
    while [ ! -f "$root/probe-entered" ] && [ "$attempts" -lt 60 ]; do sleep 1; attempts=$((attempts + 1)); done
    test -f "$root/probe-entered"
    kill -TERM "$(cat "$lock/pid")"
    reject wait "$job"
    unchanged
}
