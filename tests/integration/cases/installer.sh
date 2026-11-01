#!/bin/sh
set -eu
DESTDIR=$work/image sh tools/install.sh > /dev/null
[ -f "$work/image/usr/bin/jzm" ]
printf 'keep\n' > "$work/image/etc/zapret-manager/manager-config.json"
DESTDIR=$work/image sh tools/install.sh > /dev/null
[ "$(cat "$work/image/etc/zapret-manager/manager-config.json")" = keep ]
DESTDIR=$work/image sh tools/install.sh uninstall
[ ! -d "$work/image/etc/zapret-manager" ]
[ ! -f "$work/image/usr/bin/jzm" ]
