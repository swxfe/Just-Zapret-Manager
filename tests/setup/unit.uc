import { settings } from 'settings';
import { catalog, compose, label_strategy, replace_group } from 'strategies';
import { flowseal_strategy } from '../../tools/lib/import-strategies.uc';
import { read } from 'common';

export function fixture() {
    let home = getenv('ZM_HOME'), ctx = settings(home, null, null);
    ctx.sources = json(read(home + '/tests/fixtures/ports.json', 65536));
    ctx.resources = home + '/tests/fixtures';
    let list = catalog(ctx);
    let v7 = compose(ctx, ['v7']), games = compose(ctx, ['Gv1']);
    let joined = compose(ctx, ['v7', 'Yv08', 'Dv1']);
    let converted = flowseal_strategy(ctx, read(home + '/tests/fixtures/flowseal.bat', 65536));
    let general = label_strategy('general', converted.body);
    let flow_catalog = [{ name: 'general', body: converted.body }];
    let alt9 = replace(general, '#general\n', '#general_ALT9_\n');
    let alt_catalog = [{ name: 'general_ALT9_', body: converted.body }, ...list];
    let alt_games = replace_group(alt9, games, 'games');
    return { home, ctx, list, v7, games, joined, converted, general, flow_catalog, alt9, alt_catalog, alt_games };
};
