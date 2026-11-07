#!/bin/sh
set -eu
# Verify that the standalone artifact runs away from the source tree.
sh tools/bundle.sh >/dev/null
cp dist/just-zapret-manager.sh "$work/standalone.sh"
# Automated installation uses the same internal protocol as other mutations.
DESTDIR=$work/internal-image JZM_MODE='command' sh "$work/standalone.sh" --config "$work/manager.json" manager-install > "$work/internal-install.log"
equal_file "$work/standalone.sh" "$work/internal-image/usr/bin/jzm"
[ -x "$work/internal-image/usr/bin/jzm" ]
bad sh "$work/standalone.sh" manager-install
# Show exact package versions and known configured profiles, with independent service state.
mkdir -p "$ZM_TEST_ROOT/usr/lib/opkg"
cat > "$ZM_TEST_ROOT/usr/lib/opkg/status" <<'EOF'
Package: zapret
Version: 72.20260307-r1
Status: install ok installed

Package: luci-app-zapret
Version: 72.20260307-r1
Status: install ok installed
EOF
touch "$ZM_TEST_ROOT/mock-release"
cp "$conf" "$work/no-update.before"
cli update-upstream > "$work/no-update.out"
grep -q 'Новых версий нет' "$work/no-update.out"
equal_file "$conf" "$work/no-update.before"
rm "$ZM_TEST_ROOT/mock-release"
cli source compose flowseal base_general youtube_general
printf '0\n' | JZM_CONFIG=$work/manager.json sh "$work/standalone.sh" > "$work/dashboard.out"
grep -q 'установлен · 72.20260307-r1' "$work/dashboard.out"
if grep -q 'LuCI Zapret:' "$work/dashboard.out"; then exit 1; fi
grep -q 'youtube_general' "$work/dashboard.out"
grep -q 'base_general' "$work/dashboard.out"
mkdir -p "$ZM_TEST_ROOT/bin"
cat > "$ZM_TEST_ROOT/bin/ubus" <<'EOF'
#!/bin/sh
set -eu
[ "$*" = '-t 1 call service list {"name":"zapret"}' ]
printf '%s\n' '{"zapret":{"instances":{"nfqws":{"running":true}}}}'
EOF
chmod +x "$ZM_TEST_ROOT/bin/ubus"
touch "$ZM_TEST_ROOT/procd-running"
mv "$ZM_TEST_ROOT/etc/init.d/zapret" "$work/init-procd.saved"
printf '#!/bin/sh\nexit 99\n' > "$ZM_TEST_ROOT/etc/init.d/zapret"
chmod +x "$ZM_TEST_ROOT/etc/init.d/zapret"
printf '0\n' | JZM_CONFIG=$work/manager.json sh "$work/standalone.sh" > "$work/procd.out"
grep -q '^Сервис: запущен$' "$work/procd.out"
touch "$ZM_TEST_ROOT/procd-invalid"
printf '#!/bin/sh\nprintf "invalid\\n"\n' > "$ZM_TEST_ROOT/bin/ubus"
printf '0\n' | JZM_CONFIG=$work/manager.json sh "$work/standalone.sh" > "$work/procd-error.out"
grep -q '^Сервис: не удалось проверить$' "$work/procd-error.out"
rm "$ZM_TEST_ROOT/bin/ubus" "$ZM_TEST_ROOT/procd-invalid" "$ZM_TEST_ROOT/procd-running"
mv "$work/init-procd.saved" "$ZM_TEST_ROOT/etc/init.d/zapret"
printf '0\n' | JZM_COLOR=always JZM_CONFIG=$work/manager.json sh "$work/standalone.sh" > "$work/colors.out"
grep -q "$(printf '\033')\[32" "$work/colors.out"
# No installed files or package database: only installation is offered.
mv "$ZM_TEST_ROOT/etc/init.d/zapret" "$work/init.saved"
mv "$ZM_TEST_ROOT/usr/lib/opkg/status" "$work/status.saved"
printf '1\n0\n0\n' | JZM_CONFIG=$work/manager.json sh "$work/standalone.sh" > "$work/not-installed.out"
grep -q 'Установить Zapret' "$work/not-installed.out"
if grep -q 'Обновить Zapret\|Удалить Zapret' "$work/not-installed.out"; then exit 1; fi
mv "$work/init.saved" "$ZM_TEST_ROOT/etc/init.d/zapret"
mv "$work/status.saved" "$ZM_TEST_ROOT/usr/lib/opkg/status"
# Startup must not call extraction/temporary-directory helpers, even when they fail.
mkdir "$work/startup-bin"
for helper in mktemp tar base64 gzip; do
    printf '#!/bin/sh\nexit 99\n' > "$work/startup-bin/$helper"
    chmod +x "$work/startup-bin/$helper"
done
printf '0\n' | PATH=$work/startup-bin:$PATH JZM_CONFIG=$work/manager.json sh "$work/standalone.sh" > "$work/startup.out"
grep -q 'источник не настроен' "$work/startup.out"
printf '0\n' | JZM_CONFIG=$work/manager.json sh "$work/standalone.sh" > "$work/menu.out"
grep -q 'Установка / обновление / удаление' "$work/menu.out"
bad sh "$work/standalone.sh" help
# The payload does not reread $0, so process substitution and a streamed shell work too.
bash -c 'printf "0\n" | sh <(cat "$1")' -- "$work/standalone.sh" > "$work/substitution.out"
grep -q 'Установка / обновление / удаление' "$work/substitution.out"
cat "$work/standalone.sh" | sh > "$work/stream.out"
grep -q 'До встречи' "$work/stream.out"
printf '0\n' | JZM_CONFIG=$work/manager.json sh "$work/standalone.sh" > "$work/uninstalled-menu.out"
if grep -q 'Установить команду jzm' "$work/uninstalled-menu.out"; then exit 1; fi
# Installation is completed by the installer before the public menu opens.
DESTDIR=$work/bundle-image JZM_MODE='command' sh "$work/standalone.sh" --config "$work/manager.json" manager-install > "$work/installed.out"
equal_file "$work/standalone.sh" "$work/bundle-image/usr/bin/jzm"
[ -x "$work/bundle-image/usr/bin/jzm" ]
printf '0\n' | JZM_CONFIG=$work/manager.json DESTDIR=$work/bundle-image sh "$work/bundle-image/usr/bin/jzm" > "$work/installed-menu.out"
if grep -q 'Установить команду jzm' "$work/installed-menu.out"; then exit 1; fi
printf 'i\n\n0\n' | JZM_CONFIG=$work/manager.json DESTDIR=$work/bundle-image sh "$work/standalone.sh" > "$work/installed-shortcut.out"
grep -q 'Нет такого пункта' "$work/installed-shortcut.out"
[ ! -e "$work/bundle-image/usr/bin/jzm.previous" ]
# Reinstallation remains available through the internal protocol, not a stale menu action.
DESTDIR=$work/bundle-image JZM_MODE='command' sh "$work/standalone.sh" --config "$work/manager.json" manager-install > "$work/reinstalled.out"
equal_file "$work/standalone.sh" "$work/bundle-image/usr/bin/jzm"
equal_file "$work/standalone.sh" "$work/bundle-image/usr/bin/jzm.previous"
[ -x "$work/bundle-image/usr/bin/jzm" ]
[ -x "$work/bundle-image/usr/bin/jzm.previous" ]
printf '2\n3\n\n0\n0\n' | JZM_CONFIG=$work/manager.json sh "$work/bundle-image/usr/bin/jzm" > "$work/installed-actions.out"
cli status | grep -q running
