#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
project=$(pwd -P)
# Native package tools are replaced below. Refuse a host with live OpenWrt init
# scripts because the tested helper also refreshes rpcd after installing LuCI.
if [ -e /etc/init.d/rpcd ] || [ -e /etc/init.d/zapret ]; then
    printf '%s\n' 'package tests: skipped on a live OpenWrt host'
    exit 0
fi
stage=$(mktemp -d /tmp/zm-package-test-XXXXXX)
trap 'rm -rf -- "$stage"' 0
mkdir "$stage/bin"
JZM_PACKAGE_TEST=$stage
export JZM_PACKAGE_TEST
cat > "$stage/bin/id" <<'EOF'
#!/bin/sh
printf '0\n'
EOF
cat > "$stage/bin/opkg" <<'EOF'
#!/bin/sh
set -eu
case "$1" in
info) printf 'Size: 1024\n\n';;
status)
    if [ -f "$JZM_PACKAGE_TEST/$2" ]; then printf 'Status: install ok installed\n'; fi;;
list-upgradable)
    [ ! -f "$JZM_PACKAGE_TEST/fail-index" ] || exit 1
    if [ -f "$JZM_PACKAGE_TEST/new-core" ]; then printf 'zapret - 71 - 72\n'; fi;;
update) ;;
install|upgrade)
    printf '%s\n' "$*" >> "$JZM_PACKAGE_TEST/actions"
    shift
    for pkg in "$@"; do
        case "$pkg" in *luci-app-zapret*) touch "$JZM_PACKAGE_TEST/luci-app-zapret";;
            *zapret*) touch "$JZM_PACKAGE_TEST/zapret";; esac
    done;;
*) exit 2;;
esac
EOF
cat > "$stage/bin/curl" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = --output ]; then printf 'ZIP fixture\n' > "$2"; exit 0; fi
    shift
done
exit 2
EOF
cat > "$stage/bin/unzip" <<'EOF'
#!/bin/sh
case "$1" in
-l)
    printf '100 2026-01-01 00:00 zapret_72.20260307-r1_arch.ipk\n'
    printf '100 2026-01-01 00:00 apk/zapret-72.20260307-r1.apk\n'
    if [ ! -f "$JZM_PACKAGE_TEST/missing-luci" ]; then
        printf '100 2026-01-01 00:00 luci-app-zapret_72.20260307-r1_all.ipk\n'
        printf '100 2026-01-01 00:00 apk/luci-app-zapret-72.20260307-r1.apk\n'
    fi;;
-p) printf 'Package fixture: %s\n' "$3";;
*) exit 2;;
esac
EOF
chmod +x "$stage/bin/"*
PATH=$stage/bin:$PATH
export PATH
helper() { sh "$project/src/shell/packages.sh" "$1" '' zapret "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}"; }
# Release ZIP includes both packages; missing LuCI is repaired without core reinstall.
helper release-install https://fixture.test/release.zip '' 1 2 both > /dev/null
grep -q 'zapret_.*ipk.*luci-app-zapret_.*ipk' "$stage/actions"
: > "$stage/actions"
helper release-install https://fixture.test/release.zip '' 1 2 luci > /dev/null
grep -q 'install .*luci-app-zapret_' "$stage/actions"
if grep -q '/zapret_' "$stage/actions"; then exit 1; fi
: > "$stage/actions"
touch "$stage/missing-luci"
if helper release-install https://fixture.test/release.zip '' 1 2 both > /dev/null 2>&1; then exit 1; fi
[ ! -s "$stage/actions" ]
rm "$stage/missing-luci"
# Feeds with no newer packages must not invoke install/upgrade.
sh "$project/src/shell/packages.sh" package '' zapret update > "$stage/current.out"
[ ! -s "$stage/actions" ]
grep -q 'Новых версий нет' "$stage/current.out"
touch "$stage/new-core"
sh "$project/src/shell/packages.sh" package '' zapret update > /dev/null
grep -q '^upgrade zapret$' "$stage/actions"
rm "$stage/new-core" "$stage/luci-app-zapret"
: > "$stage/actions"
sh "$project/src/shell/packages.sh" package '' zapret update > /dev/null
grep -q '^install luci-app-zapret$' "$stage/actions"
if grep -q '^upgrade' "$stage/actions"; then exit 1; fi
touch "$stage/fail-index"
if sh "$project/src/shell/packages.sh" package '' zapret update > /dev/null 2>&1; then exit 1; fi
rm "$stage/fail-index"
# Exercise the APK path with the same fixtures and no real package manager.
cat > "$stage/bin/apk" <<'EOF'
#!/bin/sh
set -eu
case "$1" in
query) printf '%s\n' '[{"name":"zapret","installed-size":1024,"file-size":512}]';;
info) [ -f "$JZM_PACKAGE_TEST/$3" ];;
version) :;;
update) :;;
add|upgrade)
    printf '%s\n' "$*" >> "$JZM_PACKAGE_TEST/actions";;
*) exit 2;;
esac
EOF
chmod +x "$stage/bin/apk"
: > "$stage/actions"
helper release-install https://fixture.test/release.zip '' 1 2 both > /dev/null
grep -q 'add --allow-untrusted .*zapret-.*apk.*luci-app-zapret-.*apk' "$stage/actions"
: > "$stage/actions"
sh "$project/src/shell/packages.sh" package '' zapret update > /dev/null
[ ! -s "$stage/actions" ]
printf '%s\n' 'packages: core + LuCI, repair, no-op updates and index failures OK'
