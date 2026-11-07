import { settings } from '../src/lib/settings.uc';
import { read } from '../src/lib/common.uc';
import { parse_catalog, strategy_key } from '../src/lib/strategies.uc';
import { flowseal_strategy, flowseal_groups, manager_catalog } from './lib/import-strategies.uc';

let home = getenv('ZM_HOME'), input = json(read(ARGV[0], 2097152));
let ctx = settings(home, null);
ctx.sources = input.game_ports;
let flowseal = '', skipped = [];
for (let file in input.flowseal) {
    try {
        let converted = flowseal_strategy(ctx, read(file.file, 2097152));
        let groups = flowseal_groups(converted.body);
        let name = strategy_key(replace(replace(file.name, /\.bat$/i, ''), /[^A-Za-z0-9_.-]+/g, '_'));
        flowseal += '#' + name + '\n' + converted.body;
        for (let kind, body in groups) flowseal += '#' + kind + '_' + name + '\n' + body;
    }
    catch (e) { push(skipped, file.name + ': ' + e.message); }
}
let manager = manager_catalog(ctx, read(input.manager, 2097152), read(input.youtube, 2097152));
parse_catalog(ctx, flowseal);
printf('%J\n', { flowseal, manager, skipped });
