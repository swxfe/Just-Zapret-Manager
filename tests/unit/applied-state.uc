import { equal, rejects, count } from '../support/assertions.uc';
import { compose } from 'strategies';
import { normalize_options, sha256_text, strategy_hash, validate_applied, create_applied } from 'applied';
import { identify_strategy, inspect_strategy } from 'status';
import { fixture } from '../setup/unit.uc';

export function run() {
    let f = fixture();
    let ctx = f.ctx, list = f.list, v7 = f.v7, joined = f.joined, alt_games = f.alt_games, alt_catalog = f.alt_catalog;
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

};
