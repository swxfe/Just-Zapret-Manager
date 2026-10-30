#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
ZM_HOME=$(pwd -P)
JZM_REAL_UCODE=$(command -v ucode)
JZM_REAL_MV=$(command -v mv)
JZM_REAL_MKTEMP=$(command -v mktemp)
sandbox=$(mktemp -d /tmp/jzm-safety-XXXXXX)
trap 'rm -rf -- "$sandbox"' 0
ZM_TEST_ROOT=$sandbox/router
export ZM_HOME ZM_TEST_ROOT JZM_REAL_UCODE JZM_REAL_MV JZM_REAL_MKTEMP
unset ZM_TRANSACTION JZM_BOOTSTRAP JZM_BACKEND
mkdir -p "$sandbox/bin" "$ZM_TEST_ROOT/etc/config" "$ZM_TEST_ROOT/etc/init.d" "$ZM_TEST_ROOT/tmp" "$ZM_TEST_ROOT/usr/bin"
cp tests/mock-init.sh "$ZM_TEST_ROOT/etc/init.d/zapret"
chmod +x "$ZM_TEST_ROOT/etc/init.d/zapret"
printf "config main 'main'\n\toption NFQWS_OPT '--filter-tcp=443'\n" > "$ZM_TEST_ROOT/etc/config/zapret"
printf '#!/bin/sh\nprintf "0\\n"\n' > "$sandbox/bin/id"
cat > "$sandbox/bin/df" <<'EOF'
#!/bin/sh
set -eu
[ "${JZM_DF_FAIL:-0}" = 0 ] || exit 1
printf '%s\n' "$*" >> "$ZM_TEST_ROOT/df.calls"
printf 'Filesystem 1K-blocks Used Available Use%% Mounted\nfixture 999999 0 %s 0%% /\n' "${JZM_FREE_KB:-999999}"
EOF
cat > "$sandbox/bin/mv" <<'EOF'
#!/bin/sh
set -eu
for arg do
    case "$arg" in */etc/zapret-manager/update.json)
        if [ -f "$ZM_TEST_ROOT/fail-update-write" ]; then rm -f "$ZM_TEST_ROOT/fail-update-write"; exit 91; fi;;
    esac
done
exec "$JZM_REAL_MV" "$@"
EOF
cat > "$sandbox/bin/mktemp" <<'EOF'
#!/bin/sh
set -eu
template=''
for argument do template=$argument; done
case "$template" in *XXXXXX) ;; *) printf 'mktemp: invalid BusyBox template: %s\n' "$template" >&2; exit 1;; esac
exec "$JZM_REAL_MKTEMP" "$@"
EOF
cat > "$sandbox/bin/ucode" <<'EOF'
#!/bin/sh
set -eu
backend() { /bin/sh "$ZM_HOME/src/shell/backend.sh" "$1" "$ZM_TEST_ROOT" zapret "$JZM_SAFETY_INPUT" "${2:-}"; }
case "${JZM_SAFETY_STEP:-}" in
asset-abort|asset-commit|asset-reset)
    backend resource-write test.bin
    if [ "$JZM_SAFETY_STEP" = asset-reset ]; then /bin/sh "$ZM_HOME/src/shell/backend.sh" reset "$ZM_TEST_ROOT" zapret; fi
    [ "$JZM_SAFETY_STEP" != asset-abort ] || exit 73
    exit 0;;
manager-abort)
    backend manager-install "$ZM_TEST_ROOT"
    backend manager-config-init "$ZM_TEST_ROOT"
    exit 73;;
update-abort|update-commit)
    backend state-write update.json
    [ "$JZM_SAFETY_STEP" != update-abort ] || exit 73
    exit 0;;
update-signal)
    backend state-write update.json
    : > "$ZM_TEST_ROOT/update-published"
    sleep 2
    exit 0;;
esac
exec "$JZM_REAL_UCODE" "$@"
EOF
chmod +x "$sandbox/bin/"*
PATH=$sandbox/bin:$PATH
export PATH
bad() { if "$@" > "$sandbox/error" 2>&1; then printf 'expected failure: %s\n' "$*" >&2; exit 1; fi; }
backend() { sh src/shell/backend.sh "$1" "$ZM_TEST_ROOT" zapret "${2:-}" "${3:-}"; }
txn() { sh src/shell/transaction.sh transaction "$ZM_TEST_ROOT" zapret version; }
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
JZM_SAFETY_STEP=asset-abort bad txn
[ ! -e "$ZM_TEST_ROOT/opt/zapret/files/fake/test.bin" ]
JZM_SAFETY_STEP=asset-reset txn
[ ! -e "$ZM_TEST_ROOT/opt/zapret/files/fake/test.bin" ]
JZM_SAFETY_STEP=asset-commit txn
cmp "$JZM_SAFETY_INPUT" "$ZM_TEST_ROOT/opt/zapret/files/fake/test.bin"
JZM_SAFETY_STEP=asset-abort bad txn
cmp "$JZM_SAFETY_INPUT" "$ZM_TEST_ROOT/opt/zapret/files/fake/test.bin"
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
cat > "$sandbox/package-backend" <<'EOF'
#!/bin/sh
set -eu
case "$1" in
package)
    [ -z "${ZM_TRANSACTION:-}" ] && [ ! -d "$ZM_TEST_ROOT/tmp/zapret-manager.zapret.lock" ] || exit 81
    printf 'Package: zapret\nVersion: 72\nStatus: install ok installed\n' > "$ZM_TEST_ROOT/usr/lib/opkg/status"
    printf "config main 'main'\n\toption NFQWS_OPT '--filter-tcp=444'\n" > "$ZM_TEST_ROOT/etc/config/zapret"
    cp "$ZM_TEST_ROOT/etc/config/zapret" "$ZM_TEST_ROOT/package-config.before"
    : > "$ZM_TEST_ROOT/package-complete";;
transaction) [ -e "$ZM_TEST_ROOT/package-complete" ] || exit 82
    exec /bin/sh "$ZM_HOME/src/shell/backend.sh" "$@";;
*) exec /bin/sh "$ZM_HOME/src/shell/backend.sh" "$@";; esac
EOF
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
cp tests/mock-firewall.sh "$ZM_TEST_ROOT/etc/init.d/firewall"
chmod +x "$ZM_TEST_ROOT/etc/init.d/firewall"
printf "config defaults\n\toption flow_offloading '0'\n\toption flow_offloading_hw '0'\n" > "$ZM_TEST_ROOT/etc/config/firewall"
network() { JZM_MODE='command' sh src/launcher.sh --config "$sandbox/manager.json" network "$@"; }
network offload disable
network offload disable
network offload restore
bad network offload restore
if grep -q '^restart$' "$ZM_TEST_ROOT/firewall-actions"; then printf 'unchanged offloading must not restart firewall\n' >&2; exit 1; fi
printf '%s\n' 'safety: space thresholds, asset cleanup, manager rollback, update cleanup, backups and package boundary OK'
