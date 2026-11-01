#!/bin/sh
# shellcheck source=src/shell/common.sh
. "$(dirname "$0")/common.sh"

case "$action" in
transaction|recover|reset-config|reset|blockcheck|snapshot-path|snapshot-uninstall)
    exec /bin/sh "$(dirname "$0")/transaction.sh" "$action" "$root" "$profile" "$@"
    ;;
package|release-install)
    exec /bin/sh "$(dirname "$0")/packages.sh" "$action" "$root" "$profile" "$@"
    ;;
check-space) check_space "$1";;
manager-validate)
    /bin/sh -n "$1"
    JZM_MODE='command' /bin/sh "$1" version
    ;;
backup-publish)
    require_root
    [ "${ZM_TRANSACTION:-}" = "$lock" ] && [ -f "$lock/ready" ] || fail 'нет активной транзакции'
    case "$2" in "$root/tmp/"*|"$root/etc/zapret-manager/backups/"*) ;; *) fail 'неверный путь резервной копии';; esac
    case "$2" in *[!A-Za-z0-9_./\ -]*|*/../*|*/./*) fail 'неверный путь резервной копии';; esac
    [ -f "$1" ] && [ ! -L "$1" ] || fail 'неверный временный файл резервной копии'
    dir=${2%/*}
    [ "${1%/*}" = "$dir" ] || fail 'резервная копия должна публиковаться на той же файловой системе'
    physical=$(CDPATH='' cd -P "$dir" && pwd)
    [ "$physical" = "$dir" ] || fail 'каталог копии выходит за разрешённый путь'
    # link() is absent from stable ucode fs. This refuses to replace an existing backup.
    ln "$1" "$2"
    ;;
*)
    # Compatibility entry for internal atom calls; business logic lives in ucode.
    # The ordinary UI/worker invokes that logic directly and never takes this path.
    if [ -n "${JZM_BOOTSTRAP:-}" ]; then
        JZM_NATIVE_ATOM=1 JZM_MODE=command exec ucode -S -e "$JZM_BOOTSTRAP" -- backend-operation "$action" "$root" "$profile" "$@"
    else
        JZM_NATIVE_ATOM=1 JZM_MODE=command exec ucode -S -L "$ZM_HOME/src/lib" -- "$ZM_HOME/src/main.uc" backend-operation "$action" "$root" "$profile" "$@"
    fi
    ;;
esac
