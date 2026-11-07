#!/bin/sh
set -eu
cli backup save "$ZM_TEST_ROOT/etc/zapret-manager/backups/before-fakes.json"
cat > "$work/offline-http.uc" <<'EOF'
function request(url, options) { die("resource runtime attempted HTTP: " + url); }; return { request };
EOF
previous_provider=$JZM_HTTP_PROVIDER
JZM_HTTP_PROVIDER=$work/offline-http.uc
export JZM_HTTP_PROVIDER
cat > "$work/fake-strategy.txt" <<'EOF'
#custom
--filter-tcp=443
--dpi-desync=fake
--dpi-desync-fake-tls=/opt/zapret/fakes/tls_clienthello_www_google_com.bin
--new
--filter-udp=443
--dpi-desync=fake
--dpi-desync-fake-quic=/opt/zapret/fakes/tls_clienthello_www_google_com.bin
EOF
cli strategy import "$work/fake-strategy.txt"
old=/opt/zapret/fakes/tls_clienthello_www_google_com.bin
cp "$ZM_TEST_ROOT$old" "$work/original-fake.before"
ucode -S -L "$ZM_HOME/src/lib" -D "cfg=$work/manager.json" -e '
    import { settings } from "settings";
    import { fake_catalog, current_fakes } from "fakes";
    let ctx = settings(getenv("ZM_HOME"), cfg);
    assert(index(fake_catalog(ctx, "flowseal"), "tls_test.bin") != -1);
    assert(index(fake_catalog(ctx, "flowseal"), "tls_alternate.bin") != -1);
    assert(length(current_fakes(ctx)) == 2);
'
cli fake replace 3 "$old" flowseal tls_test.bin
check_applied
cli fake list > "$work/fakes.json"
flow=$(ucode -e 'print(json(require("fs").readfile(ARGV[0]))[0].path)' "$work/fakes.json")
[ -s "$ZM_TEST_ROOT$flow" ]
equal_file "$ZM_TEST_ROOT$old" "$work/original-fake.before"
cp "$ZM_TEST_ROOT/service-actions" "$work/fake-actions.before"
cp "$statefile" "$work/fake-reapply-state.before"
cli fake replace 3 "$flow" flowseal tls_test.bin
equal_file "$ZM_TEST_ROOT/service-actions" "$work/fake-actions.before"
equal_file "$statefile" "$work/fake-reapply-state.before"
python3 - "$ZM_TEST_ROOT$flow" <<'PY'
from pathlib import Path
import sys
assert Path(sys.argv[1]).read_bytes() == b"FLOWSEAL\x00\xffBINARY", "packaged binary is byte-exact"
PY

cli fake replace 3 "$flow" flowseal tls_alternate.bin
check_applied
cli config get NFQWS_OPT > "$work/fake-options"
grep -q '^--dpi-desync-fake-quic=/opt/zapret/fakes/tls_clienthello_www_google_com.bin$' "$work/fake-options"
cli fake list > "$work/fakes.json"
alternate=$(ucode -e 'print(json(require("fs").readfile(ARGV[0]))[0].path)' "$work/fakes.json")
[ "$flow" != "$alternate" ]
[ -s "$ZM_TEST_ROOT$flow" ]
cp "$conf" "$work/fake-conf.before"
cp "$statefile" "$work/fake-state.before"
find "$ZM_TEST_ROOT/opt/zapret/fakes" -type f | sort > "$work/fake-files.before"
for failure in missing empty restart stale traversal source unknown; do
    case "$failure" in
        missing) mv "$ZM_TEST_ROOT$flow" "$work/hidden-fake";;
        empty) mv "$ZM_TEST_ROOT$flow" "$work/hidden-fake"; : > "$ZM_TEST_ROOT$flow";;
        restart) touch "$ZM_TEST_ROOT/fail-restart";;
    esac
    case "$failure" in
        stale) bad cli fake replace 3 "$old" flowseal tls_test.bin;;
        traversal) bad cli fake replace 3 "$alternate" flowseal ../bad.bin;;
        source) bad cli fake replace 3 "$alternate" other tls_test.bin;;
        unknown) bad cli fake replace 3 "$alternate" flowseal nonexistent.bin;;
        *) bad cli fake replace 3 "$alternate" flowseal tls_test.bin;;
    esac
    if [ -f "$work/hidden-fake" ]; then mv "$work/hidden-fake" "$ZM_TEST_ROOT$flow"; fi
    equal_file "$conf" "$work/fake-conf.before"
    equal_file "$statefile" "$work/fake-state.before"
    find "$ZM_TEST_ROOT/opt/zapret/fakes" -type f | sort > "$work/fake-files.after"
    equal_file "$work/fake-files.before" "$work/fake-files.after"
    cli status | grep -q running
    [ ! -d "$ZM_TEST_ROOT/tmp/zapret-manager.zapret.lock" ]
done
printf '3\n5\n1\n0\n0\n0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/fake-menu.out"
grep -q '1. custom — tls_alternate.bin' "$work/fake-menu.out"
grep -q 'JZM · Фейки · замена' "$work/fake-menu.out"
if grep -q 'Ошибка:' "$work/fake-menu.out"; then cat "$work/fake-menu.out"; exit 1; fi
equal_file "$conf" "$work/fake-conf.before"
equal_file "$statefile" "$work/fake-state.before"
# The shared file appears once; choosing an occurrence and cancelling is read-only.
cli strategy import "$work/fake-strategy.txt"
cp "$conf" "$work/fake-group-conf.before"
cp "$statefile" "$work/fake-group-state.before"
printf '3\n5\n1\n2\n0\n0\n0\n0\n' | JZM_CONFIG=$work/manager.json sh src/launcher.sh > "$work/fake-group-menu.out"
python3 - "$work/fake-group-menu.out" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
main = text.split('JZM · Фейки\n', 1)[1].split('Выберите пункт:', 1)[0]
assert main.count('tls_clienthello_www_google_com.bin') == 1, main
assert [line.strip() for line in main.splitlines() if line.strip() and not line.startswith('─')] == [
    '1. custom — tls_clienthello_www_google_com.bin', '0. Назад'], main
assert '--dpi-desync-' not in main and 'профиль' not in main and 'Flowseal' not in main, main
assert '1. TLS · custom · профиль 1' in text
assert '2. QUIC · custom · профиль 2' in text
assert 'tls_clienthello_www_google_com.bin → QUIC' in text
assert 'Ошибка:' not in text
PY
equal_file "$conf" "$work/fake-group-conf.before"
equal_file "$statefile" "$work/fake-group-state.before"
cli source apply flowseal general
check_applied
cli source group manager base v98
check_applied
cli source group manager games Gv1
check_applied
cli hosts user refresh
cli hosts user add added.example
cli hosts user show > "$work/flowseal-hosts"
grep -q "^\^dns.google$" "$work/flowseal-hosts"
grep -q "^added.example$" "$work/flowseal-hosts"
cli hosts exclude refresh
[ "$(cat "$ZM_TEST_ROOT/opt/zapret/ipset/zapret-hosts-user-exclude.txt")" = refreshed.example ]
cli backup restore "$ZM_TEST_ROOT/etc/zapret-manager/backups/before-fakes.json"
JZM_HTTP_PROVIDER=$previous_provider
export JZM_HTTP_PROVIDER
printf '%s\n' 'fakes: offline catalogs, byte-exact installed assets, isolated replacement, idempotency and rollback OK'
