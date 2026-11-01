import { equal, rejects, count } from '../support/assertions.uc';
import { label_strategy, strategy_sections, parse_catalog } from 'strategies';
import { manager_catalog, flowseal_strategy } from 'sources';
import { read } from 'common';
import { inspect_strategy, strategy_summary } from 'status';
import { fixture } from '../setup/unit.uc';

export function run() {
    let f = fixture();
    let home = f.home, ctx = f.ctx, list = f.list, v7 = f.v7, converted = f.converted;
    // Catalog matching remains useful for identifying sections; provenance uses state.json.
    function catalog_identity(body, list) { return strategy_summary(inspect_strategy(body, list)); }
    assert(index(converted.body, '--wf-') == -1 && index(converted.body, '%BIN%') == -1 &&
           index(converted.body, '--ipset=') == -1, 'strip Windows-only controls'); count();
    assert(index(converted.body, '--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt') != -1,
           'map Google hostlist'); count();
    equal(converted.assets['quic_initial_steamcommunity_com.bin'],
          'bin/quic_initial_steamcommunity_com.bin', 'resolve active Discord fake alias');
    assert(index(converted.body, ctx.sources.tcp_ports) != -1, 'resolve game ports'); count();
    let general = label_strategy('general', converted.body), flow_catalog = [{ name: 'general', body: converted.body }];
    equal(length(split(general, '#general\n')), 2, 'one Flowseal heading for all internal profiles');
    equal(length(strategy_sections(general)), 1, 'Flowseal profiles stay together');
    equal(catalog_identity(general, flow_catalog), 'general', 'identify whole Flowseal preset');
    equal(catalog_identity(general + '--new\n--filter-tcp=1234\n', flow_catalog), 'general (изменена)', 'modified Flowseal section');
    equal(catalog_identity(general + '--new\n' + v7, [...flow_catalog, ...list]), 'general + v7', 'Flowseal and builtin sections');
    equal(label_strategy('general_alt', general), '#general_alt\n' + converted.body, 'relabelling emits only one heading');
    rejects(() => flowseal_strategy(ctx, '@echo off\necho hello'), 'missing winws command');
    rejects(() => flowseal_strategy(ctx, 'start x winws.exe --filter-tcp=%GameFilterTCP% --x=$(id)'), 'BAT command substitution');
    rejects(() => flowseal_strategy(ctx, 'start x winws.exe --filter-tcp=%GameFilterTCP% --x=%UNKNOWN%'), 'unknown BAT variable');
    let imported = manager_catalog(ctx, read(home + '/tests/fixtures/manager.txt', 65536),
        read(home + '/tests/fixtures/youtube.txt', 65536));
    let imported_names = map(parse_catalog(ctx, imported), (s) => s.name);
    assert(index(imported_names, 'v99') != -1 && index(imported_names, 'Dv99') != -1 &&
           index(imported_names, 'Yv99') != -1 && index(imported_names, 'Gv1') != -1,
           'migrate upstream manager catalogs as data'); count();
    rejects(() => manager_catalog(ctx, 'echo bad', '#Yv99\n--x=1'), 'missing manager strategies');
    let spaced_import = manager_catalog(ctx, "Dv99=$'--filter-tcp=443\\n--dpi-desync-autottl 2:2-12'", '#Yv99\n--x=1');
    equal(parse_catalog(ctx, spaced_import)[0].body, '--filter-tcp=443\n--dpi-desync-autottl=2:2-12\n', 'upstream separate option value is canonicalized safely');
    let spaced_youtube = manager_catalog(ctx, "Dv99=$'--filter-tcp=443'", '#Yv99\n--filter-tcp=443\n--dpi-desync-autottl 2:2-12');
    equal(parse_catalog(ctx, spaced_youtube)[1].body, '--filter-tcp=443\n--dpi-desync-autottl=2:2-12\n', 'upstream YouTube catalog canonicalizes separate values');
    rejects(() => manager_catalog(ctx, "Dv99=$'--filter-tcp=443\\n--x $(id)'", '#Yv99\n--x=1'), 'upstream separate values still reject shell injection');
};
