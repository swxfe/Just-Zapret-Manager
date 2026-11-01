import { equal, rejects, count } from '../support/assertions.uc';
import { validate_body, preserve_body, label_strategy, strategy_sections, catalog, compose, parse_catalog, replace_group, remove_flowseal, strategy_key, strategy_title, strategy_order } from 'strategies';
import { inspect_strategy, group_state, strategy_summary } from 'status';
import { fixture } from '../setup/unit.uc';

export function run() {
    let f = fixture();
    let ctx = f.ctx, list = f.list, v7 = f.v7, games = f.games, joined = f.joined, general = f.general, flow_catalog = f.flow_catalog, alt9 = f.alt9, alt_catalog = f.alt_catalog, alt_games = f.alt_games;
    // Catalog matching remains useful for identifying sections; provenance uses state.json.
    function catalog_identity(body, list) { return strategy_summary(inspect_strategy(body, list)); }
    equal(validate_body('# test\r\n --filter-tcp=443\r\n--dpi-desync=fake\n'),
          '--filter-tcp=443\n--dpi-desync=fake\n', 'strategy normalization');
    for (let bad in ['', '--new\n--filter-tcp=443', '--filter-tcp=443\n--new',
                     '--filter-tcp=443\n--new\n--new\n--filter-tcp=80',
                     '--x=$(id)', '--x=`id`', '--x=a;b', '--x="value"', '--x=a b', '--x=a\\b'])
        rejects(() => validate_body(bad), 'reject strategy');
    let max_name = 's' + sprintf('%063d', 0);
    equal(label_strategy(max_name, '--foo=1\n'), '#' + max_name + '\n--foo=1\n', 'strategy label accepts 64 bytes');
    rejects(() => label_strategy(max_name + 'x', '--foo=1\n'), 'strategy label rejects 65 bytes');
    equal(parse_catalog(ctx, ' \n\t#one \r\n --foo=1\r\n #two\n--bad=;x\n', ['one']),
        [{name: 'one', body: '--foo=1\n'}], 'select catalogue section with indented CRLF headers');
    equal(parse_catalog(ctx, '#one\n--foo=1', ['one']), [{name: 'one', body: '--foo=1\n'}], 'last catalogue body without newline');
    rejects(() => parse_catalog(ctx, '#one\n--foo=1\n#two\n--x=1\n#two\n--x=2\n', ['one']), 'check duplicate inactive headings');
    rejects(() => parse_catalog(ctx, '#one\n--foo=1\n#bad name\n--x=1\n', ['one']), 'check inactive heading syntax');
    rejects(() => parse_catalog(ctx, 'preamble\n#one\n--foo=1\n', ['one']), 'catalogue rejects text before its first heading');
    rejects(() => parse_catalog(ctx, '#one\n--bad=;x\n', ['one']), 'selected catalogue body remains fully validated');
    rejects(() => parse_catalog(ctx, '#one\n--foo=1\n#two\n--x=\x00\n', ['one']), 'catalogue rejects encoded NUL in inactive body');
    assert(length(list) > 30, 'migrated catalog'); count();
    let recognized = catalog_identity(joined, catalog(ctx));
    assert(index(recognized, 'v7') != -1 && index(recognized, 'Yv08') != -1 && index(recognized, 'Dv1') != -1,
        'identify strategies from actual UCI option values'); count();
    equal(catalog_identity('--filter-tcp=1234\n--dpi-desync=fake\n', list), 'кастомная', 'label unknown strategies honestly');
    equal(catalog_identity(null, list), 'не выбрана', 'absent option');
    equal(catalog_identity(' \n# descriptive comment\n', list), 'не выбрана', 'empty option');
    equal(catalog_identity(v7, list), 'v7', 'exact labelled preset');
    equal(catalog_identity(replace(v7, '--dpi-desync-repeats=8', '--dpi-desync-repeats=9'), list),
        'v7 (изменена)', 'labelled preset changed by hand');
    equal(catalog_identity(compose(ctx, ['v7', 'Yv08']), list), 'Yv08 + v7', 'labelled composition in runtime order');
    equal(map(strategy_sections(joined), (s) => s.label), ['Yv08', 'v7', 'Dv1'], 'one heading per composed preset');
    equal(length(split(games, '#Gv1\n')), 2, 'compound games preset has one heading');
    equal(length(strategy_sections(games)), 1, 'internal --new remains in the same section');
    equal(length(split(strategy_sections(games)[0].body, '--new\n')), 2, 'both games profiles belong to one preset');
    equal(catalog_identity(games, list), 'Gv1', 'complete compound preset');
    equal(catalog_identity(replace(games, '--dpi-desync-split-seqovl=582', '--dpi-desync-split-seqovl=583'), list),
        'Gv1 (изменена)', 'change in second internal profile changes whole preset');
    equal(catalog_identity(games + '--new\n--filter-tcp=1234\n', list), 'Gv1 (изменена)', 'added internal profile changes whole preset');
    equal(catalog_identity('#Gv1\n' + split(strategy_sections(games)[0].body, '--new\n')[0], list),
        'Gv1 (изменена)', 'removed internal profile changes whole preset');
    equal(catalog_identity(validate_body(games), list), 'Gv1', 'legacy complete compound preset');
    equal(catalog_identity(split(validate_body(games), '--new\n')[0], list), 'кастомная', 'partial preset is not a full match');
    equal(catalog_identity(v7 + '--new\n#unknown\n--filter-tcp=1234\n', list), 'v7 + unknown (изменена)', 'unknown heading stays visible');
    equal(catalog_identity('--filter-tcp=1234\n--new\n' + v7, list), 'кастомный блок + v7', 'unknown unlabelled section beside known preset');
    equal(catalog_identity('#v7\n--filter-tcp=1234\n', list), 'v7 (изменена)', 'a label cannot hide changed contents');
    equal(catalog_identity(v7 + compose(ctx, ['Yv08']), list), 'v7 (изменена) + Yv08', 'missing inter-preset separator is a change');
    equal(catalog_identity(replace(v7, '--filter-tcp=443\n', ' \t--filter-tcp=443   # port\n\n'), list),
        'v7', 'ignore comments and whitespace when comparing');
    equal(preserve_body(joined), joined, 'saving retains all preset headings');
    rejects(() => preserve_body(v7 + compose(ctx, ['Yv08'])), 'do not silently insert a missing separator');
    rejects(() => compose(ctx, ['v7', 'v7']), 'do not compose duplicate presets');
    equal(length(split(joined, '--new\n')), 3, 'strategy composition');
    assert(index(split(joined, '--new\n')[0], 'zapret-hosts-google.txt') != -1, 'Google profile precedes broad TCP profile'); count();
    rejects(() => compose(ctx, ['missing']), 'unknown strategy');
    let original = '--filter-tcp=443\n--dpi-desync=fake\n--new\n--filter-tcp=443\n--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt\n--dpi-desync=multisplit\n';
    let changed = replace_group(original, '--filter-tcp=443\n--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt\n--dpi-desync=hostfakesplit\n', 'youtube');
    assert(index(split(changed, '--new\n')[0], 'zapret-hosts-google.txt') != -1, 'replaced Google profile keeps priority'); count();
    assert(index(changed, '--dpi-desync=fake\n') != -1 && index(changed, '--dpi-desync=hostfakesplit') != -1 &&
        index(changed, '--dpi-desync=multisplit') == -1, 'replace YouTube group without losing base strategy'); count();
    let discord = replace_group('--filter-udp=19294-19344,50000-50100\n--filter-l7=discord,stun\n--dpi-desync=fake\n--new\n' +
        compose(ctx, ['v7', 'Dv1']), compose(ctx, ['Dv2']), 'discord');
    equal(length(split(discord, '--new\n')), 3, 'Discord TCP replacement preserves separate UDP voice profile');
    let regrouped = replace_group(compose(ctx, ['v7', 'Yv08', 'Gv1']), compose(ctx, ['Yv09']), 'youtube');
    equal(map(strategy_sections(regrouped), (s) => s.label), ['Yv09', 'v7', 'Gv1'], 'group replacement preserves other headings');
    equal(catalog_identity(regrouped, list), 'Yv09 + v7 + Gv1', 'group replacement keeps whole compound preset intact');
    let manual_youtube = '#Yv08\n--filter-tcp=1234\n';
    equal(replace_group(manual_youtube + '--new\n' + games, compose(ctx, ['Yv09']), 'youtube'),
        compose(ctx, ['Yv09', 'Gv1']), 'replace a manually modified labelled group');
    let partial_flowseal = replace_group(general, compose(ctx, ['Yv08']), 'youtube');
    equal(map(strategy_sections(partial_flowseal), (s) => s.label), ['Yv08', 'general'], 'retained Flowseal profiles share their original heading');
    equal(catalog_identity(partial_flowseal, [...flow_catalog, ...list]), 'Yv08 + general', 'known YouTube override accounts for removed Flowseal profiles');
    // Old cached headings and canonical names refer to the same complete Flowseal preset.
    equal(strategy_key('general_ALT9_'), 'general_alt9', 'canonical old Flowseal heading');
    equal(strategy_title('general_ALT9_'), 'general (ALT9)', 'friendly Flowseal label');
    equal(strategy_title('general'), 'general (базовый)', 'friendly base Flowseal label');
    let ordered = [{ name: 'general_alt10' }, { name: 'general_ALT9_' }, { name: 'general_alt2' }, { name: 'general' }];
    sort(ordered, strategy_order);
    equal(map(ordered, (s) => s.name), ['general', 'general_alt2', 'general_ALT9_', 'general_alt10'], 'natural preset ordering');
    equal(catalog_identity(alt9, alt_catalog), 'general_alt9', 'old heading resolves against old cache');
    equal(catalog_identity(alt_games, alt_catalog), 'general_alt9 + Gv1', 'ALT9 with exact Gv1 override is unmodified');
    equal(catalog_identity(replace(alt_games, '--filter-l7=discord,stun', '--filter-l7=discord'), alt_catalog),
        'general_alt9 (изменена) + Gv1', 'manual change in retained Flowseal still detected');
    equal(catalog_identity(replace(alt_games, '--dpi-desync-split-seqovl=582', '--dpi-desync-split-seqovl=583'), alt_catalog),
        'general_alt9 (изменена) + Gv1 (изменена)', 'modified override cannot excuse missing original profiles');
    equal(catalog_identity(replace_group(alt9, '', 'games'), alt_catalog), 'general_alt9 (изменена)', 'missing profiles without known replacement remain a change');
    equal(group_state(inspect_strategy(alt_games, alt_catalog), 'games'), 'Gv1', 'editor shows actual games override');
    equal(group_state(inspect_strategy(v7, list), 'youtube'), '[отключено]', 'editor shows absent group');
    equal(group_state(inspect_strategy(alt9, alt_catalog), 'discord'), 'general_alt9', 'editor recognizes Flowseal voice profiles');
    equal(replace_group(games, '', 'games'), '', 'disable last compound preset removes all internal profiles');
    equal(replace_group(compose(ctx, ['v7', 'Yv08', 'Gv1']), '', 'youtube'), compose(ctx, ['v7', 'Gv1']), 'disable only chosen named group');
    let without_flow = remove_flowseal(alt_games);
    equal(without_flow, games, 'disable Flowseal keeps games preset');
    equal(remove_flowseal(alt9), '', 'disable sole Flowseal preset');
    let emptied_flow = general;
    for (let group in ['base', 'youtube', 'discord', 'games']) emptied_flow = replace_group(emptied_flow, '', group);
    equal(emptied_flow, '', 'disabling all Flowseal groups removes voice too');
    equal(map(catalog(ctx, null, ['v7', 'Gv1']), (s) => s.name), ['v7', 'Gv1'], 'load only references requested by dashboard');
};
