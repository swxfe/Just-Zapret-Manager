#!/bin/sh
# shellcheck source=src/shell/common.sh
. "$(dirname "$0")/common.sh"

case "$action" in
network)
    need uci
    [ -f "$confdir/firewall" ] && [ -x "$root/etc/init.d/firewall" ] || fail 'firewall OpenWrt не найден'
    uci_cmd -q get 'firewall.@defaults[0]' >/dev/null || fail 'не найдена основная секция firewall'
    if [ "$1" = status ]; then
        printf 'Программный Flow Offloading: %s\n' "$(uci_cmd -q get 'firewall.@defaults[0].flow_offloading' || printf 0)"
        printf 'Аппаратный Flow Offloading: %s\n' "$(uci_cmd -q get 'firewall.@defaults[0].flow_offloading_hw' || printf 0)"
        if [ "$(uci_cmd -q get firewall.jzm_quic.name || :)" = JZM_Block_QUIC ]; then printf 'QUIC: заблокирован JZM\n'; else printf 'QUIC: JZM не блокирует\n'; fi
        exit 0
    fi
    require_root
    [ "${ZM_TRANSACTION:-}" = "$lock" ] || fail 'нет активной транзакции'
    : > "$lock/firewall.touched"
    case "$1:${2:-}" in
    offload:disable)
        saved=$root/etc/zapret-manager/offload.previous
        if [ ! -f "$saved" ]; then
            printf '%s\n%s\n' "$(uci_cmd -q get 'firewall.@defaults[0].flow_offloading' || printf x)" \
                "$(uci_cmd -q get 'firewall.@defaults[0].flow_offloading_hw' || printf x)" > "$lock/offload.values"
            atomic_copy "$lock/offload.values" "$saved"
        fi
        if [ "$(uci_cmd -q get 'firewall.@defaults[0].flow_offloading' || printf x)" != 0 ] ||
            [ "$(uci_cmd -q get 'firewall.@defaults[0].flow_offloading_hw' || printf x)" != 0 ]; then
            : > "$lock/firewall.restart"
        fi
        uci_cmd set 'firewall.@defaults[0].flow_offloading=0'
        uci_cmd set 'firewall.@defaults[0].flow_offloading_hw=0'
        ;;
    offload:restore)
        saved=$root/etc/zapret-manager/offload.previous
        [ -f "$saved" ] || fail 'сохранённых параметров Flow Offloading нет'
        sw=$(sed -n '1p' "$saved"); hw=$(sed -n '2p' "$saved")
        for value in "$sw" "$hw"; do case "$value" in 0|1|x) ;; *) fail 'повреждены сохранённые параметры';; esac; done
        if [ "$(uci_cmd -q get 'firewall.@defaults[0].flow_offloading' || printf x)" != "$sw" ] ||
            [ "$(uci_cmd -q get 'firewall.@defaults[0].flow_offloading_hw' || printf x)" != "$hw" ]; then
            : > "$lock/firewall.restart"
        fi
        if [ "$sw" = x ]; then uci_cmd -q delete 'firewall.@defaults[0].flow_offloading' || :
        else uci_cmd set "firewall.@defaults[0].flow_offloading=$sw"; fi
        if [ "$hw" = x ]; then uci_cmd -q delete 'firewall.@defaults[0].flow_offloading_hw' || :
        else uci_cmd set "firewall.@defaults[0].flow_offloading_hw=$hw"; fi
        mark_changed "$saved"
        rm -f "$saved"
        ;;
    quic:on|quic:off)
        existing=$(uci_cmd -q get firewall.jzm_quic.name || :)
        [ -z "$existing" ] || [ "$existing" = JZM_Block_QUIC ] || fail 'имя правила jzm_quic уже занято'
        if [ "$2" = off ]; then uci_cmd -q delete firewall.jzm_quic || :
        else
            uci_cmd set firewall.jzm_quic=rule
            uci_cmd set firewall.jzm_quic.name=JZM_Block_QUIC
            uci_cmd set firewall.jzm_quic.src=lan
            uci_cmd set firewall.jzm_quic.dest=wan
            uci_cmd set firewall.jzm_quic.proto=udp
            uci_cmd set 'firewall.jzm_quic.dest_port=80 443'
            uci_cmd set firewall.jzm_quic.target=REJECT
            uci_cmd set firewall.jzm_quic.family=any
        fi
        ;;
    *) fail 'неверная настройка совместимости';;
    esac
    mark_changed "$confdir/firewall"
    uci_cmd commit firewall
    if [ -f "$lock/firewall.restart" ]; then "$root/etc/init.d/firewall" restart
    else "$root/etc/init.d/firewall" reload; fi
    ;;
*) fail 'неизвестная операция сети';;
esac
