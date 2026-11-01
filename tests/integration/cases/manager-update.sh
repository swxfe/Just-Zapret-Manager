#!/bin/sh
set -eu
# Updates use the configured repository only and install atomically with a previous copy.
mkdir -p "$ZM_TEST_ROOT/usr/bin"
cp "$work/standalone.sh" "$ZM_TEST_ROOT/usr/bin/jzm"
sed 's/0\.1\.[0-9][0-9]*/0.2.0/g' "$work/standalone.sh" > "$ZM_TEST_ROOT/manager-release"
ucode -S -D "source=$work/manager.json" -D "target=$work/update-config.json" -e '
    import * as fs from "fs";
    let c = json(fs.readfile(source));
    c.updater.repo = "jzm-fixture/manager";
    fs.writefile(target, sprintf("%J\n", c));
'
JZM_UPDATE_CONFIG=$work/update-config.json ucode -S -L "$ZM_HOME/src/lib" tests/integration/manager-update.uc
python3 tests/performance/navigation.py "$work/manager.json" "$work/faults.so"
