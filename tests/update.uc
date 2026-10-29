import * as fs from 'fs';
import { settings } from 'settings';
import { check, read } from 'common';
import { check_update, update_status, apply_update } from 'manager';

let ctx = settings(getenv('ZM_HOME'), getenv('JZM_UPDATE_CONFIG'));
let path = ctx.root + '/usr/bin/jzm';
let before = read(path, ctx.max_file_bytes);
check(!update_status(ctx).available, 'no update before metadata check');
let info = check_update(ctx);
check(info.available && info.version == '0.2.0', 'offer newer release');
apply_update(ctx);
check(read(path + '.previous', ctx.max_file_bytes) == before, 'preserve previous executable');
let installed = read(path, ctx.max_file_bytes);
check(index(installed, '# JZM_VERSION=0.2.0\n') != -1, 'install selected release');
fs.writefile(ctx.root + '/manager-release', '#!/bin/sh\n# JZM_FORMAT=2\n# JZM_VERSION=0.3.0\nif then\n');
check_update(ctx);
let rejected = false;
try { apply_update(ctx); }
catch (e) { rejected = true; }
check(rejected && read(path, ctx.max_file_bytes) == installed, 'invalid update preserves executable');
fs.writefile(ctx.root + '/update-offline', '1');
rejected = false;
try { check_update(ctx); }
catch (e) { rejected = true; }
check(rejected && update_status(ctx).version == '0.3.0', 'offline check preserves last metadata');
print('update: version check, installation, previous copy and rejection OK\n');
