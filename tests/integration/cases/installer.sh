#!/bin/sh
set -eu
DESTDIR=$work/image sh tools/install.sh > /dev/null
[ -f "$work/image/usr/bin/jzm" ]
ucode -S -D "image=$work/image" -e '
    import * as fs from "fs";
    for (let directory in ["/opt", "/opt/zapret", "/opt/zapret/fakes"])
        assert((fs.stat(image + directory).mode & 0777) == 0755, "daemon must traverse new fake directories");
    for (let name in fs.lsdir(image + "/opt/zapret/fakes"))
        assert((fs.stat(image + "/opt/zapret/fakes/" + name).mode & 0777) == 0644, "daemon must read installed fakes");
'

printf 'keep\n' > "$work/image/etc/zapret-manager/manager-config.json"
DESTDIR=$work/image sh tools/install.sh > /dev/null
[ "$(cat "$work/image/etc/zapret-manager/manager-config.json")" = keep ]
DESTDIR=$work/image sh tools/install.sh uninstall
[ ! -d "$work/image/etc/zapret-manager" ]
[ ! -f "$work/image/usr/bin/jzm" ]
