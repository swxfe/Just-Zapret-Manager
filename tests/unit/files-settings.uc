import { equal, rejects, count } from '../support/assertions.uc';
import * as fs from 'fs';
import { catalog } from 'strategies';
import { settings } from 'settings';
import { read, tempdir } from 'common';
import { read_applied, create_applied } from 'applied';
import { inspect_strategy } from 'status';
import { fixture } from '../setup/unit.uc';

export function run() {
    let f = fixture();
    let home = f.home, ctx = f.ctx, list = f.list, v7 = f.v7;
    equal(ctx.profile, 'zapret', 'default profile');
    let original_state = create_applied(v7, inspect_strategy(v7, list), list, 123);
    let dir = tempdir();
    assert(dir != null, 'temporary directory');
    let file = dir + '/sample';
    fs.writefile(file, '#one\n--x=1\n#one\n--x=2\n');
    rejects(() => catalog(ctx, file), 'duplicate strategy');
    fs.writefile(file, 'abc\x00def');
    rejects(() => read(file, 128), 'NUL input');
    fs.writefile(file, 'abcdef');
    rejects(() => read(file, 2), 'file size limit');
    fs.writefile(file, '{"profile":"zapret","root":"/../etc"}');
    rejects(() => settings(home, file, null), 'path traversal');
    fs.writefile(file, '{"profile":"zapret","unexpected":1}');
    rejects(() => settings(home, file, null), 'unknown setting');
    let state_ctx = { state: dir };
    equal(read_applied(state_ctx), null, 'missing state file');
    fs.writefile(dir + '/state.json', sprintf('%J', original_state));
    equal(read_applied(state_ctx), original_state, 'read saved applied state');
    fs.writefile(dir + '/state.json', '{broken');
    rejects(() => read_applied(state_ctx), 'reject corrupted state JSON');
    fs.unlink(dir + '/state.json');
    // A real file called @default must never alias the embedded-catalog cache key.
    let cached_ctx = { ...ctx, cache: {} }, previous_directory = fs.getcwd();
    catalog(cached_ctx);
    fs.writefile(dir + '/@default', '#local\n--x=1\n');
    fs.chdir(dir);
    try { equal(catalog(cached_ctx, '@default')[0].name, 'local', 'file path cannot collide with builtin catalog cache'); }
    catch (e) { fs.chdir(previous_directory); fs.unlink(dir + '/@default'); die(e.message); }
    fs.chdir(previous_directory);
    fs.unlink(dir + '/@default');
    fs.unlink(file);
    fs.rmdir(dir);
};
