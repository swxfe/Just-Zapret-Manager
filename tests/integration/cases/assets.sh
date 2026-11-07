#!/bin/sh
set -eu
python3 - "$JZM_ASSETS_ARCHIVE" <<'PY'
import json, sys, tarfile
with tarfile.open(sys.argv[1]) as archive:
    manifest = json.load(archive.extractfile('manifest.json'))
    assert {entry['source'] for entry in manifest['origins']} == {'flowseal', 'manager'}
    assert {entry['source'] for entry in manifest['fakes']} == {'flowseal'}
    assert not any(name.startswith(('defaults/', 'fakes/flowseal/')) for name in archive.getnames())
    assert all(entry['path'] == 'fakes/' + entry['name'] for entry in manifest['files'] if entry['target'] == 'fake')
    assert all(entry['path'] == '/opt/zapret/fakes/' + entry['name'] for entry in manifest['fakes'])
    assert {entry['name'] for entry in manifest['files'] if entry['target'] == 'catalog'} == {'flowseal.json', 'manager.json'}
PY
cli source list manager > "$work/manager-names"
grep -q '^v99$' "$work/manager-names"
grep -q '^Dv99$' "$work/manager-names"
grep -q '^Yv99$' "$work/manager-names"
grep -q '^Yv100$' "$work/manager-names"
grep -q '^Gv1$' "$work/manager-names"
cli source show manager v98 > "$work/manager-alias.opts"
grep -q '^--dpi-desync-fake-tls=/opt/zapret/fakes/tls_clienthello_4pda_to.bin$' "$work/manager-alias.opts"
[ ! -e "$ZM_TEST_ROOT/opt/zapret/fakes/4pda.bin" ]
# An identically named package payload must survive every asset installation.
mkdir -p "$ZM_TEST_ROOT/opt/zapret/files/fake"
printf 'PACKAGE MAX PAYLOAD\n' > "$ZM_TEST_ROOT/opt/zapret/files/fake/tls_clienthello_max_ru.bin"
cp "$ZM_TEST_ROOT/opt/zapret/files/fake/tls_clienthello_max_ru.bin" "$work/package-max.before"
# All archive resources are installed once; ordinary startup must never unpack them.
cp "$conf" "$work/assets-conf.before"
cp "$statefile" "$work/assets-state.before"
cp "$hosts" "$work/assets-user.before"
cp "$ZM_TEST_ROOT/etc/zapret-manager/assets/manifest.json" "$work/assets-manifest.before"
cp "$ZM_TEST_ROOT/service-actions" "$work/assets-service.before"
bad cli source apply manager Yv100
equal_file "$conf" "$work/assets-conf.before"
equal_file "$statefile" "$work/assets-state.before"
equal_file "$ZM_TEST_ROOT/service-actions" "$work/assets-service.before"
printf '3\n2\n2\n0\n0\n0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/missing-manager.out"
grep -q 'Yv100.*нет фейка: missing-manager-only.bin' "$work/missing-manager.out"
equal_file "$conf" "$work/assets-conf.before"
assets_digest() {
    find "$ZM_TEST_ROOT/etc/zapret-manager/assets" "$ZM_TEST_ROOT/opt/zapret/fakes" -type f -exec sha256sum {} + | sort
}
cli assets-install "$JZM_ASSETS_ARCHIVE" >/dev/null
equal_file "$ZM_TEST_ROOT/opt/zapret/files/fake/tls_clienthello_max_ru.bin" "$work/package-max.before"
[ -s "$ZM_TEST_ROOT/opt/zapret/fakes/tls_clienthello_max_ru.bin" ]
assets_digest > "$work/assets.before"
cli assets-install "$JZM_ASSETS_ARCHIVE" >/dev/null
assets_digest > "$work/assets.after"
equal_file "$work/assets.before" "$work/assets.after"
equal_file "$conf" "$work/assets-conf.before"
equal_file "$hosts" "$work/assets-user.before"
equal_file "$ZM_TEST_ROOT/service-actions" "$work/assets-service.before"
for failure in version foreign-source traversal forbidden duplicate oversize checksum missing symlink extra duplicate-member syntax-catalog syntax-config syntax-network syntax-urls syntax-list; do
    python3 tests/assets/mutate.py "$JZM_ASSETS_ARCHIVE" "$work/bad-assets.tar.gz" "$failure"
    bad cli assets-install "$work/bad-assets.tar.gz"
    assets_digest > "$work/assets.after"
    equal_file "$work/assets.before" "$work/assets.after"
    equal_file "$ZM_TEST_ROOT/opt/zapret/files/fake/tls_clienthello_max_ru.bin" "$work/package-max.before"
    equal_file "$conf" "$work/assets-conf.before"
    equal_file "$statefile" "$work/assets-state.before"
    equal_file "$hosts" "$work/assets-user.before"
    equal_file "$ZM_TEST_ROOT/service-actions" "$work/assets-service.before"
    [ ! -d "$ZM_TEST_ROOT/tmp/zapret-manager.zapret.lock" ]
done
# Failure after assets were published must restore all of them through the journal.
python3 tests/assets/mutate.py "$JZM_ASSETS_ARCHIVE" "$work/changed-assets.tar.gz" changed
touch "$ZM_TEST_ROOT/fail-assets-write"
bad env LD_PRELOAD="$work/faults.so" JZM_MODE=command sh src/launcher.sh --config "$work/manager.json" assets-install "$work/changed-assets.tar.gz"
assets_digest > "$work/assets.after"
equal_file "$work/assets.before" "$work/assets.after"
equal_file "$conf" "$work/assets-conf.before"
equal_file "$statefile" "$work/assets-state.before"
equal_file "$hosts" "$work/assets-user.before"
# Successful reinstallation updates packaged binaries and cached lists, preserving live user lists.
cli assets-install "$work/changed-assets.tar.gz" >/dev/null
python3 - "$work/changed-assets.tar.gz" "$ZM_TEST_ROOT" <<'PY'
from pathlib import Path
import json, sys, tarfile
with tarfile.open(sys.argv[1]) as archive:
    manifest = json.load(archive.extractfile('manifest.json'))
    for entry in manifest['files']:
        if entry['target'] == 'fake':
            assert (Path(sys.argv[2]) / 'opt/zapret/fakes' / entry['name']).read_bytes() == archive.extractfile(entry['path']).read()
PY
grep -q '^changed-from-new-release.example$' "$ZM_TEST_ROOT/etc/zapret-manager/assets/resources/exclude.txt"
equal_file "$hosts" "$work/assets-user.before"
cli assets-install "$JZM_ASSETS_ARCHIVE" >/dev/null
assets_digest > "$work/assets.after"
equal_file "$work/assets.before" "$work/assets.after"
equal_file "$ZM_TEST_ROOT/opt/zapret/files/fake/tls_clienthello_max_ru.bin" "$work/package-max.before"
# Generated code carries neither catalog/list contents nor the old acquisition pipeline.
sh tools/bundle.sh >/dev/null
if grep -Eq 'EMBEDDED_(STRATEGIES|DATA|CONFIG)|function (identify_fake|download_fake|refresh_source|windows_tokens)|created_fakes|resource-bytes|resource-write|sha1' dist/just-zapret-manager.sh; then exit 1; fi
if grep -Fq 'refreshed.example' dist/just-zapret-manager.sh; then exit 1; fi
printf '%s\n' 'assets: offline installation, idempotency, 16 hostile archives, publication rollback and data-free code OK'
