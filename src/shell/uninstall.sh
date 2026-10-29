#!/bin/sh
# shellcheck source=src/shell/common.sh
. "$(dirname "$0")/common.sh"

require_root
[ "${ZM_TRANSACTION:-}" = "$lock" ] || fail 'нет активной транзакции удаления'
case "${1:-}" in manager|all) mode=$1;; *) fail 'ожидается manager или all';; esac
state=$root/etc/zapret-manager
# Snapshot complete trees, including backups and downloaded catalogs, before deletion.
for tree in state zapret; do
    [ "$tree" != zapret ] || [ "$mode" = all ] || continue
    if [ "$tree" = state ]; then path=$state; else path=$base; fi
    [ ! -L "$path" ] || fail "отказ удалять символическую ссылку: $path"
    if [ -d "$path" ]; then cp -pR "$path" "$lock/uninstall-$tree"
    else : > "$lock/uninstall-$tree.absent"; fi
done
: > "$lock/uninstall.ready"

saved=$state/offload.previous
if [ -f "$saved" ]; then
    sw=$(sed -n '1p' "$saved"); hw=$(sed -n '2p' "$saved")
    for value in "$sw" "$hw"; do case "$value" in 0|1|x) ;; *) fail 'повреждены сохранённые параметры Flow Offloading';; esac; done
    for option in flow_offloading flow_offloading_hw; do
        if [ "$option" = flow_offloading ]; then value=$sw; else value=$hw; fi
        current=$(uci_cmd -q get "firewall.@defaults[0].$option" || printf x)
        [ "$current" = "$value" ] || : > "$lock/firewall.restart"
        if [ "$value" = x ]; then uci_cmd -q delete "firewall.@defaults[0].$option" || :
        else uci_cmd set "firewall.@defaults[0].$option=$value"; fi
    done
    : > "$lock/firewall.touched"
fi
if [ -f "$confdir/firewall" ] && [ "$(uci_cmd -q get firewall.jzm_quic.name || :)" = JZM_Block_QUIC ]; then
    uci_cmd delete firewall.jzm_quic
    : > "$lock/firewall.touched"
fi
if [ -f "$lock/firewall.touched" ]; then
    mark_changed "$confdir/firewall"
    uci_cmd commit firewall
    if [ -f "$lock/firewall.restart" ]; then "$root/etc/init.d/firewall" restart
    else "$root/etc/init.d/firewall" reload; fi
fi

cronfile=$root/etc/crontabs/root
tag='# zapret-manager:zapret'
if [ -f "$cronfile" ] && grep -q "$tag$" "$cronfile"; then
    cp -p "$cronfile" "$lock/cron.before"
    awk -v tag="$tag" 'length($0)<length(tag) || substr($0,length($0)-length(tag)+1)!=tag' "$cronfile" > "$lock/cron.after"
    atomic_copy "$lock/cron.after" "$cronfile"
    "$root/etc/init.d/cron" restart
fi

hook=$base/init.d/openwrt/custom.d/20-jzm-exclude.sh
if [ "$mode" = manager ]; then
    if [ -e "$hook" ] || [ -L "$hook" ]; then
        mark_changed "$hook"
        rm -f "$hook"
        if [ -f "$state/legacy-exclusion-hook.sh" ]; then
            legacy=$base/init.d/openwrt/custom.d/20-script.sh
            [ ! -e "$legacy" ] || fail 'старый хук уже существует; удаление отменено'
            atomic_copy "$state/legacy-exclusion-hook.sh" "$legacy"
        fi
        if [ -x "$init" ] && "$init" running >/dev/null 2>&1; then service restart; fi
    fi
else
    mark_changed "$config"
    rm -f "$config"
    # Both paths are fixed whitelist roots; package removal has already succeeded.
    rm -rf -- "$base"
fi
mark_changed "$root/usr/bin/jzm"
mark_changed "$root/usr/bin/jzm.previous"
rm -f "$root/usr/bin/jzm" "$root/usr/bin/jzm.previous"
rm -rf -- "$state"
