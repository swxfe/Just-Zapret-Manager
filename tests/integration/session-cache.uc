import * as fs from 'fs';
import { settings } from 'settings';
import { session_cache, invalidate } from 'cache';
import { command_main } from 'commands';
import { configured_strategy, strategy_state, package_versions } from 'status';
import { source_data } from 'sources';
import { output } from 'common';

let ctx = settings(getenv('ZM_HOME'), ARGV[0]);
session_cache(ctx);
let argv = ['--config', ctx.file, 'config', 'set', 'DISABLE_IPV6'];
let original = trim(output(ctx, 'config-get', ['DISABLE_IPV6']));
let changed = original == '1' ? '0' : '1';
ctx.cache.sentinel = true;
assert(command_main([...argv, original], ctx) == 0, 'no-op succeeds');
assert(ctx.cache.sentinel == true, 'no-op preserves warm session cache');
assert(command_main([...argv, 'invalid'], ctx) == 1, 'invalid setting fails');
assert(ctx.cache.sentinel == true, 'input rejection preserves cache');
let before = fs.readfile(ctx.config);
fs.writefile(ctx.root + '/fail-restart', '1');
assert(command_main([...argv, changed], ctx) == 1, 'restart fault fails');
assert(fs.readfile(ctx.config) == before && ctx.cache.sentinel == true, 'rollback preserves state and cache');
assert(command_main([...argv, changed], ctx) == 0, 'committed change succeeds');
assert(!exists(ctx.cache, 'sentinel') && trim(output(ctx, 'config-get', ['DISABLE_IPV6'])) == changed,
    'commit invalidates cache and next read sees committed state');
assert(command_main([...argv, original], ctx) == 0, 'restore original option');

// Once warm, navigation must still work if unchanged inputs temporarily disappear.
let source = source_data(ctx, 'flowseal'), body = configured_strategy(ctx);
let strategy = strategy_state(ctx), packages = package_versions(ctx);
let hidden = ctx.root + '/tmp/session-config';
assert(fs.rename(ctx.config, hidden), 'hide fixture configuration');
try {
    assert(configured_strategy(ctx) == body && strategy_state(ctx).summary == strategy.summary, 'no config reread');
    assert(source_data(ctx, 'flowseal').revision == source.revision, 'no catalog reread');
    assert(sprintf('%J', package_versions(ctx)) == sprintf('%J', packages), 'no package reread');
    invalidate(ctx);
    assert(configured_strategy(ctx) == '', 'invalidation observes missing configuration');
}
catch (e) { fs.rename(hidden, ctx.config); die(e.message); }
assert(fs.rename(hidden, ctx.config), 'restore fixture configuration');
print('session: no-op, failure, rollback, commit invalidation and warm reads OK\n');
