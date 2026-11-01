#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
. tests/setup/packages.sh

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
cp tests/mocks/packages/apk.sh "$stage/bin/apk"
chmod +x "$stage/bin/apk"
: > "$stage/actions"
helper release-install https://fixture.test/release.zip '' 1 2 both > /dev/null
grep -q 'add --allow-untrusted .*zapret-.*apk.*luci-app-zapret-.*apk' "$stage/actions"
: > "$stage/actions"
sh "$project/src/shell/packages.sh" package '' zapret update > /dev/null
[ ! -s "$stage/actions" ]
printf '%s\n' 'packages: core + LuCI, repair, no-op updates and index failures OK'
