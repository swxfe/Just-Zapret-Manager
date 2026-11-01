import { settings } from 'settings';
import { session_cache } from 'cache';
import { command_main } from 'commands';
import { output } from 'common';
import { sha256_text } from 'applied';

let ctx = settings(getenv('ZM_HOME'), ARGV[0]);
session_cache(ctx);
for (let args in [['status'], ['config', 'get', 'DISABLE_IPV6'], ['config', 'show'],
    ['hosts', 'user', 'show'], ['devices', 'list'], ['network', 'status'],
    ['source', 'list', 'manager'], ['source', 'show', 'manager', 'v99'],
    ['strategy', 'list'], ['strategy', 'show', 'v7']])
    assert(command_main(['--config', ctx.file, ...args], ctx) == 0, 'native read-only: ' + join(' ', args));
assert(trim(output(ctx, 'architecture')) == 'test_arch', 'native architecture');
assert(length(sha256_text('read-only hash')) == 64, 'native hash');
