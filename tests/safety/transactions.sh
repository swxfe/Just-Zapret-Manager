#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
. tests/setup/safety.sh

export JZM_FREE_KB=5119
bad backend check-space 0
export JZM_FREE_KB=5120
backend check-space 0
export JZM_FREE_KB=5319
bad backend check-space 100
export JZM_FREE_KB=5320
backend check-space 100
tail -n 1 "$ZM_TEST_ROOT/df.calls" | grep -q "$ZM_TEST_ROOT$"
mkdir "$ZM_TEST_ROOT/overlay"
backend check-space 100
tail -n 1 "$ZM_TEST_ROOT/df.calls" | grep -q "$ZM_TEST_ROOT/overlay$"
JZM_DF_FAIL=1 bad backend check-space 0
export JZM_FREE_KB=999999
JZM_SAFETY_INPUT=$sandbox/payload
export JZM_SAFETY_INPUT
printf 'FAKE\n' > "$JZM_SAFETY_INPUT"
JZM_SAFETY_STEP=dynamic-abort bad txn
[ ! -e "$ZM_TEST_ROOT/etc/zapret-manager/exported.txt" ]
printf 'original export\n' > "$ZM_TEST_ROOT/etc/zapret-manager/exported.txt"
cp -p "$ZM_TEST_ROOT/etc/zapret-manager/exported.txt" "$sandbox/export.before"
JZM_SAFETY_STEP=dynamic-abort bad txn
cmp "$sandbox/export.before" "$ZM_TEST_ROOT/etc/zapret-manager/exported.txt"
JZM_SAFETY_STEP=asset-abort bad txn
[ ! -e "$ZM_TEST_ROOT/opt/zapret/fakes/test.bin" ]
JZM_SAFETY_STEP=asset-reset txn
[ ! -e "$ZM_TEST_ROOT/opt/zapret/fakes/test.bin" ]
JZM_SAFETY_STEP=asset-commit txn
cmp "$JZM_SAFETY_INPUT" "$ZM_TEST_ROOT/opt/zapret/fakes/test.bin"
JZM_SAFETY_STEP=asset-abort bad txn
cmp "$JZM_SAFETY_INPUT" "$ZM_TEST_ROOT/opt/zapret/fakes/test.bin"
printf '#!/bin/sh\nprintf old\n' > "$ZM_TEST_ROOT/usr/bin/jzm"
printf '#!/bin/sh\nprintf previous\n' > "$ZM_TEST_ROOT/usr/bin/jzm.previous"
chmod 700 "$ZM_TEST_ROOT/usr/bin/jzm"
chmod 740 "$ZM_TEST_ROOT/usr/bin/jzm.previous"
manager_metadata() {
    "$JZM_REAL_UCODE" -S -e 'import * as fs from "fs"; for(let path in ARGV) { let s=fs.stat(path); printf("%J\n",[s.mode,s.uid,s.gid,s.mtime]); }' -- \
        "$ZM_TEST_ROOT/usr/bin/jzm" "$ZM_TEST_ROOT/usr/bin/jzm.previous"
}
original_metadata=$(manager_metadata)
cp "$ZM_TEST_ROOT/usr/bin/jzm" "$sandbox/old"
cp "$ZM_TEST_ROOT/usr/bin/jzm.previous" "$sandbox/previous"
printf '#!/bin/sh\nprintf new\n' > "$JZM_SAFETY_INPUT"
JZM_SAFETY_STEP=manager-abort bad txn
cmp "$sandbox/old" "$ZM_TEST_ROOT/usr/bin/jzm"
cmp "$sandbox/previous" "$ZM_TEST_ROOT/usr/bin/jzm.previous"
[ "$(manager_metadata)" = "$original_metadata" ]
[ ! -e "$ZM_TEST_ROOT/etc/zapret-manager/manager-config.json" ]
# Installing identical contents still changes modes; the write journal must restore them.
cp "$sandbox/old" "$JZM_SAFETY_INPUT"
JZM_SAFETY_STEP=manager-abort bad txn
cmp "$sandbox/old" "$ZM_TEST_ROOT/usr/bin/jzm"
cmp "$sandbox/previous" "$ZM_TEST_ROOT/usr/bin/jzm.previous"
[ "$(manager_metadata)" = "$original_metadata" ]
printf '{"before":true}\n' > "$ZM_TEST_ROOT/etc/zapret-manager/update.json"
cp "$ZM_TEST_ROOT/etc/zapret-manager/update.json" "$sandbox/update.before"
printf '{"after":true}\n' > "$JZM_SAFETY_INPUT"
JZM_SAFETY_STEP=update-abort bad txn
cmp "$sandbox/update.before" "$ZM_TEST_ROOT/etc/zapret-manager/update.json"
touch "$ZM_TEST_ROOT/fail-update-write"
JZM_SAFETY_STEP=update-abort bad txn
cmp "$sandbox/update.before" "$ZM_TEST_ROOT/etc/zapret-manager/update.json"
JZM_SAFETY_STEP=update-signal txn > "$sandbox/signal.log" 2>&1 &
job=$!
attempt=0
while [ ! -e "$ZM_TEST_ROOT/update-published" ] && [ "$attempt" -lt 100 ]; do sleep 0.1; attempt=$((attempt + 1)); done
[ -e "$ZM_TEST_ROOT/update-published" ]
kill -TERM "$(cat "$ZM_TEST_ROOT/tmp/zapret-manager.zapret.lock/pid")"
if wait "$job"; then printf 'interrupted update succeeded\n' >&2; exit 1; fi
cmp "$sandbox/update.before" "$ZM_TEST_ROOT/etc/zapret-manager/update.json"
for temporary in "$ZM_TEST_ROOT/etc/zapret-manager/".update-*; do [ ! -e "$temporary" ]; done
JZM_SAFETY_STEP=update-commit txn
cmp "$JZM_SAFETY_INPUT" "$ZM_TEST_ROOT/etc/zapret-manager/update.json"
for temporary in "$ZM_TEST_ROOT/etc/zapret-manager/".update-*; do [ ! -e "$temporary" ]; done
backend backup-write "$JZM_SAFETY_INPUT" "$ZM_TEST_ROOT/etc/zapret-manager/backups/backup.json"
[ -s "$ZM_TEST_ROOT/etc/zapret-manager/backups/backup.json" ]
bad backend backup-write "$JZM_SAFETY_INPUT" "$sandbox/outside.json"
[ ! -e "$sandbox/outside.json" ]
unset JZM_SAFETY_STEP
# Equal payloads must replace a symlink before chmod, never change its outside target.
hook=$ZM_TEST_ROOT/opt/zapret/init.d/openwrt/custom.d/20-jzm-exclude.sh
mkdir -p "$(dirname "$hook")"
cp "$JZM_SAFETY_INPUT" "$sandbox/outside-hook"
chmod 600 "$sandbox/outside-hook"
ln -s "$sandbox/outside-hook" "$hook"
backend device-hook-write "$JZM_SAFETY_INPUT"
[ ! -L "$hook" ]
"$JZM_REAL_UCODE" -S -e 'import * as fs from "fs"; assert((fs.stat(ARGV[0]).mode & 0777) == 0600);' -- "$sandbox/outside-hook"
cmp "$JZM_SAFETY_INPUT" "$hook"
# The package shim models a successful external package operation, then a config failure.
"$JZM_REAL_UCODE" -S -D "root=$ZM_TEST_ROOT" -D "destination=$sandbox/manager.json" -e '
    import * as fs from "fs";
    let c=json(fs.readfile("data/manager.json")); c.root=root; c.settle_seconds=0;
    fs.writefile(destination,sprintf("%J\n",c));
'
mkdir -p "$ZM_TEST_ROOT/usr/lib/opkg"
printf 'Package: zapret\nVersion: 71\nStatus: install ok installed\n' > "$ZM_TEST_ROOT/usr/lib/opkg/status"
cp tests/mocks/safety/package-backend.sh "$sandbox/package-backend"
JZM_SAFETY_BACKEND=$sandbox/package-backend
export JZM_SAFETY_BACKEND
JZM_BACKEND=$(cat <<'EOF'
exec /bin/sh "$JZM_SAFETY_BACKEND" "$@"
EOF
)
export JZM_BACKEND
touch "$ZM_TEST_ROOT/fail-restart"
bad env JZM_MODE=command sh src/launcher.sh --config "$sandbox/manager.json" update
cmp "$ZM_TEST_ROOT/package-config.before" "$ZM_TEST_ROOT/etc/config/zapret"
grep -q 'Version: 72' "$ZM_TEST_ROOT/usr/lib/opkg/status"
[ ! -d "$ZM_TEST_ROOT/tmp/zapret-manager.zapret.lock" ]
unset JZM_BACKEND
cp tests/mocks/firewall.sh "$ZM_TEST_ROOT/etc/init.d/firewall"
chmod +x "$ZM_TEST_ROOT/etc/init.d/firewall"
printf "config defaults\n\toption flow_offloading '0'\n\toption flow_offloading_hw '0'\n" > "$ZM_TEST_ROOT/etc/config/firewall"
network() { JZM_MODE='command' sh src/launcher.sh --config "$sandbox/manager.json" network "$@"; }
network offload disable
network offload disable
network offload restore
bad network offload restore
if grep -q '^restart$' "$ZM_TEST_ROOT/firewall-actions"; then printf 'unchanged offloading must not restart firewall\n' >&2; exit 1; fi
printf '%s\n' 'safety: space thresholds, asset cleanup, manager rollback, update cleanup, backups and package boundary OK'
