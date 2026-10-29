#!/bin/sh
# shellcheck source=src/shell/common.sh
. "$(dirname "$0")/common.sh"

package_manager() {
    if command -v apk >/dev/null 2>&1; then manager=apk; extension=apk
    elif command -v opkg >/dev/null 2>&1; then manager=opkg; extension=ipk
    else fail 'не найден opkg или apk'
    fi
}
package_present() {
    if [ "$manager" = apk ]; then apk info -e "$1" >/dev/null 2>&1
    else opkg status "$1" | awk '$1=="Status:" && $NF=="installed" {found=1} END {exit !found}'
    fi
}
install_files() {
    install_kb=0
    for install_file do install_kb=$((install_kb + $(file_kb "$install_file"))); done
    check_space "$install_kb"
    if [ "$manager" = opkg ]; then opkg install "$@"
    else
        printf '%s\n' 'Локальные APK: используется --allow-untrusted для сборки Zapret и LuCI.'
        apk add --allow-untrusted "$@"
    fi
    check_space 0
}
feed_space() {
    if [ "$manager" = opkg ]; then
        package_info=$(opkg info "$@") || fail 'не удалось получить размеры пакетов'
        package_bytes=$(printf '%s\n' "$package_info" | awk '
            /^Size: [0-9]+$/ {sum+=$2; count++}
            END {if (!count) exit 1; printf "%.0f",sum}') || fail 'в метаданных пакетов отсутствует Size'
    else
        package_info=$(apk query --recursive --format json --fields name,installed-size,file-size "$@") || fail 'не удалось получить размеры APK'
        package_bytes=$(printf '%s\n' "$package_info" | ucode -S -e '
            import { stdin } from "fs";
            let list=json(stdin.read("all")), total=0;
            if (type(list)!="array" || !length(list)) die("APK: нет размеров пакетов");
            for (let p in list) {
                let installed=p["installed-size"], file=p["file-size"];
                if (type(installed)!="int" || type(file)!="int" || installed<0 || file<0) die("APK: неверный размер");
                total += installed > file ? installed : file;
            }
            printf("%.0f",total);
        ') || fail 'не удалось проверить размеры APK'
    fi
    case "$package_bytes" in ''|*[!0-9]*) fail 'неверный размер пакета';; esac
    check_space "$(( (package_bytes + 1023) / 1024 ))"
}
luci_ready() {
    if [ -x "$root/etc/init.d/rpcd" ]; then "$root/etc/init.d/rpcd" restart; fi
    printf '%s\n' 'LuCI Zapret установлен. Обновите страницу LuCI: Сервисы → Zapret.'
}

case "$action" in
release-install)
    require_root
    [ -z "${ZM_TRANSACTION:-}" ] || fail 'пакеты нельзя устанавливать внутри транзакции конфигов'
    [ -z "$root" ] || fail 'установка релиза возможна только на роутере'
    need curl
    package_manager
    components=$5
    case "$components" in both|luci) ;; *) fail 'неверный набор пакетов';; esac
    check_space "${6:-16384}"
    if ! command -v unzip >/dev/null 2>&1; then
        check_space 0
        "$manager" update
        feed_space unzip
        if [ "$manager" = opkg ]; then opkg install unzip; else apk add unzip; fi
        check_space 0
    fi
    stage=$(mktemp -d /tmp/zm-release-XXXXXX)
    trap 'rm -rf -- "$stage"' 0
    curl --fail --location --show-error --proto '=https' --proto-redir '=https' \
        --connect-timeout "$3" --max-time "$4" --max-filesize 16777216 --output "$stage/release.zip" "$1"
    if [ -n "$2" ]; then
        need sha256sum
        printf '%s  %s\n' "$2" "$stage/release.zip" | sha256sum -c - || fail 'SHA256 архива не совпал'
    fi
    unzip -l "$stage/release.zip" > "$stage/members"
    set --
    # Validate and extract every selected package before invoking the package manager.
    for name in zapret luci-app-zapret; do
        [ "$components:$name" != luci:zapret ] || continue
        if [ "$manager" = opkg ]; then pattern="^${name}_[A-Za-z0-9_.+-]+[.]ipk$"
        else pattern="^apk/${name}-[A-Za-z0-9_.+-]+[.]apk$"
        fi
        member=$(awk -v pattern="$pattern" '$4 ~ pattern && $1+0>0 && $1+0<=16777216 {print $4}' "$stage/members")
        [ "$(printf '%s\n' "$member" | wc -l)" -eq 1 ] && [ -n "$member" ] || fail "в релизе не найден единственный пакет $name"
        package=$stage/$(basename "$member")
        unzip -p "$stage/release.zip" "$member" > "$package"
        [ -s "$package" ] && [ "$(wc -c < "$package")" -le 16777216 ] || fail "неверный размер пакета $name"
        set -- "$@" "$package"
    done
    install_files "$@"
    luci_ready
    ;;
package)
    require_root
    [ -z "${ZM_TRANSACTION:-}" ] || fail 'пакеты нельзя изменять внутри транзакции конфигов'
    [ -z "$root" ] || fail 'установка пакетов возможна только при root="/"'
    verb=$1; shift
    package_manager
    for pkg in "$@"; do
        case "$(basename "$pkg")" in
            zapret[_-]*."$extension"|luci-app-zapret[_-]*."$extension") ;;
            *) fail "неверный пакет для $manager: $pkg";;
        esac
        [ -f "$pkg" ] || fail "пакет не найден: $pkg"
    done
    case "$verb" in
    install|update)
        check_space 0
        if [ "$#" -gt 0 ]; then
            stage=$(mktemp -d /tmp/zm-local-XXXXXX)
            trap 'rm -rf -- "$stage"' 0
            for pkg in "$@"; do cp "$pkg" "$stage/$(basename "$pkg")"; done
            install_files "$stage/"*."$extension"
        else
            "$manager" update
            if [ "$verb" = install ]; then
                feed_space zapret luci-app-zapret
                if [ "$manager" = opkg ]; then opkg install zapret luci-app-zapret
                else apk add zapret luci-app-zapret; fi
            else
                if [ "$manager" = opkg ]; then
                    pending=$(opkg list-upgradable)
                    pending=$(printf '%s\n' "$pending" | awk '$1=="zapret" || $1=="luci-app-zapret" {print $1}')
                else
                    pending=$(apk version -l '<' zapret luci-app-zapret)
                    pending=$(printf '%s\n' "$pending" | awk '
                        $1 ~ /^zapret-[0-9]/ {print "zapret"}
                        $1 ~ /^luci-app-zapret-[0-9]/ {print "luci-app-zapret"}')
                fi
                changed=0
                for name in zapret luci-app-zapret; do
                    if ! package_present "$name"; then
                        feed_space "$name"
                        if [ "$manager" = opkg ]; then opkg install "$name"; else apk add "$name"; fi
                        check_space 0
                        changed=1
                    elif printf '%s\n' "$pending" | awk -v name="$name" '$0==name {found=1} END{exit !found}'; then
                        feed_space "$name"
                        if [ "$manager" = opkg ]; then opkg upgrade "$name"; else apk upgrade "$name"; fi
                        check_space 0
                        changed=1
                    fi
                done
                if [ "$changed" = 0 ]; then
                    printf '%s\n' 'Zapret и LuCI актуальны. Новых версий нет, переустановка не требуется.'
                    exit 0
                fi
            fi
        fi
        check_space 0
        if package_present luci-app-zapret; then luci_ready
        else fail 'Zapret установлен, но luci-app-zapret отсутствует; установка не завершена'
        fi
        ;;
    remove)
        if [ -x "$init" ]; then service stop; service disable; fi
        set --
        for name in luci-app-zapret zapret; do if package_present "$name"; then set -- "$@" "$name"; fi; done
        if [ "$#" -gt 0 ]; then
            if [ "$manager" = opkg ]; then opkg remove "$@"; else apk del "$@"; fi
        fi
        ;;
    *) fail 'неверная операция пакета';;
    esac
    ;;
*) fail 'неизвестная операция пакета';;
esac
