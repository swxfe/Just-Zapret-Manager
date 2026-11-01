#!/bin/sh
set -eu
hook=$1
hooklog=$2
case "$3" in relaxed) set +eu;; strict) :;; *) exit 2;; esac
nft() {
    case "$1" in
        -a)
            [ "$ready" = 1 ] || return 1
            if [ -s "$hooklog" ]; then printf '%s\n' 'comment "jzm_devices"'; fi
            ;;
        insert) printf '%s\n' "$*" >> "$hooklog";;
        *) return 2;;
    esac
}
options=$-
# The generated hook is checked with sh -n and ShellCheck by its calling test.
# shellcheck source=/dev/null
. "$hook"
[ "$-" = "$options" ] || exit 1
[ ! -e "$hooklog" ] || exit 1
ready=0
if zapret_custom_firewall_nft; then exit 1; fi
[ ! -e "$hooklog" ] || exit 1
ready=1
zapret_custom_firewall_nft || exit 1
zapret_custom_firewall_nft || exit 1
[ "$(wc -l < "$hooklog")" -eq 1 ] || exit 1
grep -q '192.168.1.20' "$hooklog" || exit 1
