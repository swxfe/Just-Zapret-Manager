#!/bin/sh
set -eu
# Schedule changes must preserve every unrelated crontab line, including other Zapret jobs.
mkdir -p "$ZM_TEST_ROOT/etc/crontabs"
printf '7 1 * * * /root/other-zapret-job\n' > "$ZM_TEST_ROOT/etc/crontabs/root"
cp "$ZM_TEST_ROOT/etc/crontabs/root" "$work/cron.before"
cli schedule 3 "$work/urls.txt" "$work/catalog.txt"
grep -q '^0 3 .*# zapret-manager:zapret$' "$ZM_TEST_ROOT/etc/crontabs/root"
grep -q '^7 1 ' "$ZM_TEST_ROOT/etc/crontabs/root"
cli schedule off
equal_file "$ZM_TEST_ROOT/etc/crontabs/root" "$work/cron.before"
touch "$ZM_TEST_ROOT/fail-cron"
bad cli schedule 3 "$work/urls.txt" "$work/catalog.txt"
equal_file "$ZM_TEST_ROOT/etc/crontabs/root" "$work/cron.before"
# Recover a stale, complete snapshot without guessing or deleting unrelated paths.
lock=$ZM_TEST_ROOT/tmp/zapret-manager.zapret.lock
cp "$conf" "$work/recovery.before"
mkdir "$lock"
printf '2147483647\n' > "$lock/pid"
cp "$conf" "$lock/0"
cp "$hosts" "$lock/1"
cp "$ZM_TEST_ROOT/opt/zapret/ipset/zapret-hosts-user-exclude.txt" "$lock/2"
cp "$ZM_TEST_ROOT/opt/zapret/ipset/zapret-hosts-google.txt" "$lock/3"
touch "$lock/ready" "$lock/running"
printf 'corrupted\n' > "$conf"
printf 'corrupted\n' > "$hosts"
cli recover
equal_file "$conf" "$work/recovery.before"
equal_file "$hosts" "$work/hosts.before"
cli status | grep -q running
# Signal the supervisor while a helper is still running; rollback waits for that helper.
cp "$conf" "$work/signal.before"
cp "$statefile" "$work/signal-state.before"
touch "$ZM_TEST_ROOT/pause-probe"
cli benchmark "$work/urls.txt" "$work/catalog.txt" > "$work/signal.log" 2>&1 &
job=$!
attempt=0
while [ ! -f "$ZM_TEST_ROOT/probe-entered" ] && [ "$attempt" -lt 100 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
done
[ -f "$ZM_TEST_ROOT/probe-entered" ]
kill -TERM "$(cat "$lock/pid")"
if wait "$job"; then printf '%s\n' 'interrupted benchmark succeeded unexpectedly' >&2; exit 1; fi
equal_file "$conf" "$work/signal.before"
equal_file "$statefile" "$work/signal-state.before"
cli status | grep -q running
[ ! -d "$lock" ]
