import * as fs from 'fs';
import { domains, urls, validate_list_snapshot } from 'domains';
import { validate_body, preserve_body, label_strategy, strategy_sections, catalog, compose, parse_catalog, replace_group, remove_flowseal, strategy_key, strategy_title, strategy_order } from 'strategies';
import { manager_catalog, flowseal_strategy, github_response } from 'sources';
import { ipv4, exclusion_hook, legacy_addresses } from 'devices';
import { settings } from 'settings';
import { read, tempdir } from 'common';
import { newer_version } from 'manager';
import { normalize_options, sha256_text, strategy_hash, validate_applied, read_applied, create_applied, applied_catalog_hash } from 'applied';
import { parse_packages, identify_strategy, release_plan, release_compare, inspect_strategy, group_state, procd_running, strategy_summary } from 'status';

let passed = 0;
function equal(value, expected, name) {
    assert(sprintf('%J', value) == sprintf('%J', expected), sprintf('%s: expected %J, got %J', name, expected, value));
    passed++;
}
function rejects(fn, name) {
    let failed = false;
    try { fn(); } catch (e) { failed = true; }
    assert(failed, name);
    passed++;
}

// Catalog matching remains useful for identifying sections; provenance uses state.json.
function catalog_identity(body, list) { return strategy_summary(inspect_strategy(body, list)); }

equal(domains('EXAMPLE.COM\r\nexample.com # duplicate\nsub.example.com\n', 3),
      ['example.com', 'sub.example.com'], 'normalization and deduplication');
equal(domains('', 1), [], 'empty list');
equal(validate_list_snapshot('# package defaults\n127.0.0.0/8\n::1\nfc00::/7\nru\nрф\nexample.com\n', 8, 1024), true, 'backup preserves upstream mixed list formats');
rejects(() => validate_list_snapshot('a\x00b', 8, 1024), 'backup rejects NUL bytes');
rejects(() => validate_list_snapshot('a\nb\n', 1, 1024), 'backup list line limit');
rejects(() => validate_list_snapshot('example.com', 8, 4), 'backup list byte limit');
let wide_line = '';
for (let i = 0; i < 512; i++) wide_line += 'я';
equal(validate_list_snapshot(wide_line + '\n', 1, 4096), true, 'backup accepts exactly 1024 UTF-8 bytes');
rejects(() => validate_list_snapshot(wide_line + 'x\n', 1, 4096), 'backup byte width is not a Unicode character count');
equal(validate_list_snapshot(' \t\r\n\nfirst\n \r\nsecond', 2, 4096), true, 'backup counts nonblank lines and final unterminated line');
rejects(() => validate_list_snapshot('first\n\x01second', 2, 4096), 'backup checks control bytes after newlines');
for (let bad in ['-host.com', 'host-.com', 'a..com', '*.example.com', 'x.com;id', 'https://x.com', 'a b.com'])
    rejects(() => domains(bad, 8), 'reject domain ' + bad);
rejects(() => domains('one.com\ntwo.com', 1), 'domain limit');
let max_label = 'a' + sprintf('%062d', 0);
equal(domains(max_label + '.test', 1), [max_label + '.test'], 'DNS label accepts 63 bytes');
rejects(() => domains(max_label + 'x.test', 1), 'DNS label rejects 64 bytes');
equal(urls('# comment\nhttps://example.com/path?a=1&b=2\n', 2),
      ['https://example.com/path?a=1&b=2'], 'URL parser');
equal(urls('https://redirector.googlevideo.com/report_mapping\n', 1),
      ['https://redirector.googlevideo.com/report_mapping'], 'Googlevideo mapping URL');
equal(github_response('200\n59\n{"sha":"test"}'), '{"sha":"test"}', 'GitHub success body');
equal(github_response('200\n\n{}'), '{}', 'GitHub success without remaining header');
equal(github_response('200\n59\n{"commit":{"message":"Fix rate limit exceeded"}}'),
      '{"commit":{"message":"Fix rate limit exceeded"}}', 'commit message is not an API error');
function api_error(response, expected) {
    let message = '';
    try { github_response(response); } catch (e) { message = e.message; }
    assert(index(message, expected) != -1, sprintf('API diagnostic: expected %s, got %s', expected, message));
    passed++;
}
for (let response in ['403\n0\n{}', '403\n\n{"message":"API rate limit exceeded for IP"}',
                     '403\n10\n{"message":"You have exceeded a secondary rate limit."}',
                     '429\n\n<html>Too many requests</html>'])
    api_error(response, 'Превышен лимит запросов GitHub API (60/час на ваш IP)');
api_error('403\n59\n{"message":"Resource not accessible"}', 'ошибка HTTP 403');
api_error('404\n59\n{"message":"Not Found"}', 'ошибка HTTP 404');
api_error('503\n\n<html>Unavailable</html>', 'ошибка HTTP 503');
rejects(() => github_response('broken'), 'reject missing API status');
rejects(() => github_response('000\n\n{}'), 'reject invalid API status');
for (let bad in ['file:///etc/passwd', 'https://example.com\n--output x', '', 'https://user:pw@host.test'])
    rejects(() => urls(bad, 2), 'reject URL');
rejects(() => urls('https://one.com\nhttps://two.com', 1), 'URL limit');
equal(validate_body('# test\r\n --filter-tcp=443\r\n--dpi-desync=fake\n'),
      '--filter-tcp=443\n--dpi-desync=fake\n', 'strategy normalization');
for (let bad in ['', '--new\n--filter-tcp=443', '--filter-tcp=443\n--new',
                 '--filter-tcp=443\n--new\n--new\n--filter-tcp=80',
                 '--x=$(id)', '--x=`id`', '--x=a;b', '--x="value"', '--x=a b', '--x=a\\b'])
    rejects(() => validate_body(bad), 'reject strategy');
let home = getenv('ZM_HOME');
equal(newer_version('10.10.0', '10.9.9'), true, 'compare versions numerically');
equal(newer_version('10.2.0', '10.2.0'), false, 'same version needs no update');
equal(newer_version('9.99.9', '10.2.0'), false, 'never offer downgrade');
rejects(() => newer_version('10.2.0;id', '10.2.0'), 'reject invalid update version');
let ctx = settings(home, null, null);
equal(parse_packages('Package: zapret\nVersion: 72.20260307-r1\nStatus: install ok installed\n\nPackage: luci-app-zapret\nVersion: 72.20260307-r1\nStatus: deinstall ok config-files\n', 'opkg'),
    { zapret: '72.20260307-r1' }, 'opkg removed packages are not installed');
equal(parse_packages('P:zapret\nV:72.20260307-r1\n\nP:luci-app-zapret\nV:72.20260307-r1\n', 'apk'),
    { zapret: '72.20260307-r1', 'luci-app-zapret': '72.20260307-r1' }, 'read APK database versions');
let max_version = sprintf('%0100d', 0);
equal(parse_packages('P:zapret\nV:' + max_version + '\n', 'apk'), {zapret: max_version}, 'package version accepts 100 bytes');
equal(parse_packages('P:zapret\nV:' + max_version + '0\n', 'apk'), {}, 'package version rejects 101 bytes');
equal(release_plan({}, 'v72.20260307'), 'both', 'new installation includes LuCI');
equal(release_plan({ zapret: '72.20260307-r1' }, 'v72.20260307'), 'luci', 'repair missing LuCI without reinstalling core');
equal(release_plan({ zapret: '72.20260307-r1', 'luci-app-zapret': '72.20260307-r1' }, 'v72.20260307'),
    'none', 'skip installation when release is current');
equal(release_plan({ zapret: '72.20250101-r1' }, 'v72.20260307'), 'both', 'update an older core with LuCI');
equal(release_compare('72.20260307-r1', 'v72.20260307'), 0, 'compare package to release tag');
rejects(() => release_plan({ zapret: '73.20270101-r1' }, 'v72.20260307'), 'never repair LuCI from an older incompatible release');
equal(ctx.profile, 'zapret', 'default profile');
let list = catalog(ctx);
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
assert(length(list) > 30, 'migrated catalog'); passed++;
let joined = compose(ctx, ['v7', 'Yv08', 'Dv1']);
let recognized = catalog_identity(joined, catalog(ctx));
assert(index(recognized, 'v7') != -1 && index(recognized, 'Yv08') != -1 && index(recognized, 'Dv1') != -1,
    'identify strategies from actual UCI option values'); passed++;
equal(catalog_identity('--filter-tcp=1234\n--dpi-desync=fake\n', list), 'кастомная', 'label unknown strategies honestly');
equal(catalog_identity(null, list), 'не выбрана', 'absent option');
equal(catalog_identity(' \n# descriptive comment\n', list), 'не выбрана', 'empty option');
let v7 = compose(ctx, ['v7']), games = compose(ctx, ['Gv1']);
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
assert(index(split(joined, '--new\n')[0], 'zapret-hosts-google.txt') != -1, 'Google profile precedes broad TCP profile'); passed++;
rejects(() => compose(ctx, ['missing']), 'unknown strategy');
let converted = flowseal_strategy(ctx, read(home + '/tests/fixtures/flowseal.bat', 65536));
assert(index(converted.body, '--wf-') == -1 && index(converted.body, '%BIN%') == -1 &&
       index(converted.body, '--ipset=') == -1, 'strip Windows-only controls'); passed++;
assert(index(converted.body, '--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt') != -1,
       'map Google hostlist'); passed++;
equal(converted.assets['quic_initial_steamcommunity_com.bin'],
      'bin/quic_initial_steamcommunity_com.bin', 'resolve active Discord fake alias');
assert(index(converted.body, ctx.sources.tcp_ports) != -1, 'resolve game ports'); passed++;
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
       'migrate upstream manager catalogs as data'); passed++;
rejects(() => manager_catalog(ctx, 'echo bad', '#Yv99\n--x=1'), 'missing manager strategies');
let spaced_import = manager_catalog(ctx, "Dv99=$'--filter-tcp=443\\n--dpi-desync-autottl 2:2-12'", '#Yv99\n--x=1');
equal(parse_catalog(ctx, spaced_import)[0].body, '--filter-tcp=443\n--dpi-desync-autottl=2:2-12\n', 'upstream separate option value is canonicalized safely');
let spaced_youtube = manager_catalog(ctx, "Dv99=$'--filter-tcp=443'", '#Yv99\n--filter-tcp=443\n--dpi-desync-autottl 2:2-12');
equal(parse_catalog(ctx, spaced_youtube)[1].body, '--filter-tcp=443\n--dpi-desync-autottl=2:2-12\n', 'upstream YouTube catalog canonicalizes separate values');
rejects(() => manager_catalog(ctx, "Dv99=$'--filter-tcp=443\\n--x $(id)'", '#Yv99\n--x=1'), 'upstream separate values still reject shell injection');
let original = '--filter-tcp=443\n--dpi-desync=fake\n--new\n--filter-tcp=443\n--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt\n--dpi-desync=multisplit\n';
let changed = replace_group(original, '--filter-tcp=443\n--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt\n--dpi-desync=hostfakesplit\n', 'youtube');
assert(index(split(changed, '--new\n')[0], 'zapret-hosts-google.txt') != -1, 'replaced Google profile keeps priority'); passed++;
assert(index(changed, '--dpi-desync=fake\n') != -1 && index(changed, '--dpi-desync=hostfakesplit') != -1 &&
    index(changed, '--dpi-desync=multisplit') == -1, 'replace YouTube group without losing base strategy'); passed++;
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
let alt9 = replace(general, '#general\n', '#general_ALT9_\n');
let alt_catalog = [{ name: 'general_ALT9_', body: converted.body }, ...list];
equal(catalog_identity(alt9, alt_catalog), 'general_alt9', 'old heading resolves against old cache');
let alt_games = replace_group(alt9, games, 'games');
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
equal(procd_running({ zapret: { instances: { nfqws: { running: true } } } }), true, 'procd running instance');
equal(procd_running({ zapret: { instances: { nfqws: { running: false } } } }), false, 'procd stopped instance');
equal(procd_running({}), false, 'procd missing service is stopped');
rejects(() => procd_running(null), 'invalid procd response is not reported as stopped');
equal(parse_packages('C:checksum\nP:irrelevant\nV:1\n\nC:checksum\nP:zapret\nV:72.20260307-r1\n', 'apk'),
    { zapret: '72.20260307-r1' }, 'APK package name need not be first field');

// Hashes cover real nfqws words; comments and formatting have no runtime effect.
equal(sha256_text(''), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 'SHA256 empty vector');
equal(sha256_text('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', 'SHA256 standard vector');
equal(normalize_options('#v7\n  --x=1  --y=2 # note\n\n'), '--x=1\n--y=2\n', 'canonical option words');
equal(strategy_hash(v7), strategy_hash(replace(v7, '--filter-tcp=443\n', ' --filter-tcp=443 # port\n')), 'formatting does not change applied hash');
let original_state = create_applied(v7, inspect_strategy(v7, list), list, 123);
let new_catalog = map(list, (s) => ({ name: s.name, body: s.name == 'v7' ? replace(s.body, '--dpi-desync-repeats=8', '--dpi-desync-repeats=10') : s.body }));
let manual_v7 = replace(v7, '--dpi-desync-repeats=8', '--dpi-desync-repeats=9');
equal(identify_strategy(v7, list, original_state), 'v7', 'state matrix: clean and current');
equal(identify_strategy(v7, new_catalog, original_state), 'v7 (доступно обновление)', 'state matrix: upstream update only');
equal(identify_strategy(manual_v7, list, original_state), 'v7 (изменена пользователем)', 'state matrix: manual edits only');
equal(identify_strategy(manual_v7, new_catalog, original_state), 'v7 (изменена вами, есть обновление)', 'state matrix: manual and upstream conflict');
equal(identify_strategy(v7, new_catalog, original_state), 'v7 (доступно обновление)', 'status checks never change applied baseline');
equal(identify_strategy(v7, list, null), 'кастомная', 'no state cannot establish provenance');
equal(identify_strategy('', list, original_state), 'не выбрана', 'empty config overrides recorded state');
equal(identify_strategy('# empty\n', list, null), 'не выбрана', 'comment-only config');
equal(identify_strategy(v7, [], original_state), 'кастомная', 'missing catalog reference cannot be called an upstream update');
equal(original_state.applied_at, 123, 'record application timestamp');
equal(original_state.name, 'v7', 'record applied name');
equal(original_state.applied_hash, strategy_hash(v7), 'record canonical applied hash');
equal(identify_strategy(v7, list, { name: 'v7', applied_hash: original_state.applied_hash, applied_at: 123 }), 'v7', 'three-field state remains supported');
let composed_state = create_applied(joined, inspect_strategy(joined, list), list, 124);
equal(identify_strategy(joined, list, composed_state), 'Yv08 + v7 + Dv1', 'exact assembly catalog hash');
equal(identify_strategy(joined, new_catalog, composed_state), 'Yv08 + v7 + Dv1 (доступно обновление)', 'update in one assembly member');
equal(identify_strategy(replace(joined, '--dpi-desync-repeats=8', '--dpi-desync-repeats=9'), list, composed_state),
    'Yv08 + v7 + Dv1 (изменена пользователем)', 'manual assembly change');
equal(identify_strategy(v7 + compose(ctx, ['Yv08']), list, create_applied(compose(ctx, ['v7', 'Yv08']),
    inspect_strategy(compose(ctx, ['v7', 'Yv08']), list), list, 125)),
    'Yv08 + v7 (изменена пользователем)', 'hash does not insert a missing --new boundary');
let alt_state = create_applied(alt_games, inspect_strategy(alt_games, alt_catalog), alt_catalog, 126);
equal(identify_strategy(alt_games, alt_catalog, alt_state), 'general_alt9 + Gv1', 'snapshot records effective Flowseal composition');
equal(alt_state.sections[0].omit, ['games'], 'save Flowseal projection in applied recipe');
let new_alt_catalog = map(alt_catalog, (s) => ({ name: s.name, body: replace(s.body, '--filter-l7=discord,stun', '--filter-l7=discord') }));
equal(identify_strategy(alt_games, new_alt_catalog, alt_state), 'general_alt9 + Gv1 (доступно обновление)', 'detect Flowseal update without inspecting modified config for recipe');
let custom = '--filter-tcp=1234\n--dpi-desync=fake\n';
let custom_state = create_applied(custom, inspect_strategy(custom, list), list, 127);
equal(custom_state.name, 'кастомная', 'import records custom strategy name');
equal(custom_state.applied_hash, strategy_hash(custom), 'import records custom strategy hash');
equal(identify_strategy(custom, list, custom_state), 'кастомная', 'custom import has no catalog reference');
rejects(() => validate_applied({ name: 'v7', applied_hash: 'bad', applied_at: 1 }), 'reject malformed saved hash');
rejects(() => validate_applied({ name: 'v7', applied_hash: original_state.applied_hash, applied_at: -1 }), 'reject invalid timestamp');
rejects(() => validate_applied({ ...original_state, sections: [{ name: '../etc', omit: [] }] }), 'reject invalid recipe name');
rejects(() => validate_applied({ ...original_state, sections: [{ name: 'v7', omit: ['invalid'] }] }), 'reject invalid profile projection');

equal(sha256_text("a'$(printf NEVER_EXECUTED)`printf NEVER_EXECUTED`\\b\nПривет"), "daa9d94cf7dc4226b4b89951bdb61084c140905654ee6cc7b11a2c1ce11adc06", 'hash input is literal shell data');

equal(legacy_addresses("EXCEPT_SRC='{ 192.168.1.10, 192.168.1.20 }'\nnft insert rule inet zapret postrouting_hook index 0 \\\n  ip saddr $EXCEPT_SRC meta mark set meta mark \\| 0x40000000\n"),
    ['192.168.1.10', '192.168.1.20'], 'recognize original device exclusion hook without executing it');
equal(legacy_addresses('#!/bin/sh\necho custom\n'), null, 'preserve unrelated custom hooks');
equal(legacy_addresses("EXCEPT_SRC='{ 192.168.1.1 }'\nnft insert rule inet zapret postrouting_hook index 0 ip saddr $EXCEPT_SRC meta mark set meta mark \\| 0x40000000\nreboot\n"),
    null, 'reject extended legacy hook');
equal(ipv4('192.168.001.20'), '192.168.1.20', 'canonical IPv4');
for (let bad in ['256.1.1.1', '1.2.3', '1.2.3.4;id', '1.2.3.-1', '::1']) rejects(() => ipv4(bad), 'reject invalid client address');
let hook = exclusion_hook(ctx, ['192.168.1.20']);
assert(index(hook, "ip saddr '{ 192.168.1.20 }'") != -1 && index(hook, '\\| 0x40000000') != -1,
    'generate literal nft match and escaped mark operator'); passed++;
rejects(() => exclusion_hook(ctx, ['1.2.3.4;id']), 'never generate shell from invalid address');
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
fs.unlink(file);
fs.rmdir(dir);
printf('unit: %d checks passed\n', passed);
