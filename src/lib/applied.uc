import * as fs from 'fs';
import { check, read } from 'common';
import { strategy_key, profile_group } from 'strategies';

// Exact text keys keep manual edits visible; bound the cache to four 64 KiB inputs.
let digest_cache = [];

export function normalize_options(body) {
    let words = [], separators = /[[:space:]]+/;
    for (let raw in split(body || '', '\n')) {
        let line = trim(split(raw, '#')[0]);
        if (length(line)) for (let word in split(line, separators)) push(words, word);
    }
    return length(words) ? join('\n', words) + '\n' : '';
};

export function sha256_text(text) {
    check(type(text) == 'string' && length(text) <= 65536 && index(text, '\x00') == -1, 'неверные данные для SHA256');
    for (let entry in digest_cache) if (entry.text == text) return entry.digest;
    // Quote every byte, including user-supplied apostrophes; printf never interprets data as code.
    let quoted = "'" + replace(text, /'/g, "'\\''") + "'";
    check(length(quoted) < 100000, 'слишком большие данные для SHA256');
    let proc = fs.popen("printf '%s' " + quoted + ' | sha256sum', 'r');
    check(proc != null, 'не удалось запустить sha256sum');
    let reply = proc.read(256) || '', rc = proc.close();
    let digest = match(reply, /^([a-f0-9]+)[ \t]+[*]?-/);
    check(rc == 0 && digest && length(digest[1]) == 64, 'не удалось вычислить SHA256; нужна команда sha256sum');
    if (length(digest_cache) == 4) shift(digest_cache);
    push(digest_cache, { text, digest: digest[1] });
    return digest[1];
};

export function strategy_hash(body) {
    return sha256_text(normalize_options(body));
};

export function validate_applied(state) {
    check(type(state) == 'object' && type(state.name) == 'string' && length(state.name) > 0 &&
        length(state.name) <= 4096 && index(state.name, '\x00') == -1 && !match(state.name, /[\x01-\x1f\x7f]/) &&
        type(state.applied_hash) == 'string' && length(state.applied_hash) == 64 && match(state.applied_hash, /^[a-f0-9]+$/) &&
        type(state.applied_at) == 'int' && state.applied_at >= 0, 'повреждён state.json');
    if (state.sections != null) {
        let name_pattern = /^[A-Za-z0-9][A-Za-z0-9_.-]*$/;
        check(type(state.sections) == 'array' && length(state.sections) <= 1024, 'неверный состав state.json');
        for (let section in state.sections) {
            check(type(section) == 'object' && (section.name == null || (type(section.name) == 'string' &&
                length(section.name) <= 64 && match(section.name, name_pattern))) &&
                type(section.omit) == 'array' && length(section.omit) <= 5, 'неверная секция state.json');
            for (let group in section.omit) check(index(['base', 'youtube', 'discord', 'games', 'voice'], group) != -1,
                'неверная группа state.json');
        }
    }
    return state;
};

export function read_applied(ctx) {
    let path = ctx.state + '/state.json';
    return fs.stat(path) ? validate_applied(json(read(path, 65536))) : null;
};

export function applied_names(state) {
    if (state == null) return [];
    return state.sections != null ? map(state.sections, (s) => strategy_key(s.name)) :
        map(split(state.name, /[ \t]*\+[ \t]*/), (name) => strategy_key(name));
};

function reference_index(list) {
    let result = {};
    for (let item in list) {
        let name = strategy_key(item.name);
        if (result[name] == null) result[name] = normalize_options(item.body);
    }
    return result;
}

function applied_profile_kind(block) {
    return profile_group(block) || (index(block, '--filter-l7=discord,stun') != -1 ? 'voice' : null);
}

export function create_applied(body, sections, list, applied_at) {
    let refs = reference_index(list), recipe = [], names = [];
    for (let section in sections) {
        let name = strategy_key(section.name), omit = [];
        if (name != null && refs[name] != null && match(name, /^general(_|$)/)) {
            let current = map(split(normalize_options(section.body), '--new\n'), applied_profile_kind);
            let original = map(split(refs[name], '--new\n'), applied_profile_kind);
            for (let group in ['base', 'youtube', 'discord', 'games', 'voice'])
                if (index(original, group) != -1 && index(current, group) == -1) push(omit, group);
        }
        push(recipe, { name, omit });
        push(names, name || 'кастомный блок');
    }
    let name = length(filter(recipe, (s) => s.name != null)) ? join(' + ', names) : 'кастомная';
    if (!length(normalize_options(body))) name = 'не выбрана';
    return validate_applied({ name, applied_hash: strategy_hash(body), applied_at, sections: recipe });
};

export function applied_catalog_hash(state, list) {
    if (state == null) return null;
    validate_applied(state);
    let refs = reference_index(list), bodies = [];
    let recipe = state.sections != null ? state.sections : map(applied_names(state), (name) => ({ name, omit: [] }));
    for (let section in recipe) {
        let ref = refs[strategy_key(section.name)];
        if (section.name == null || ref == null) return null;
        let blocks = filter(split(ref, '--new\n'), (block) => index(section.omit, applied_profile_kind(block)) == -1);
        if (length(blocks)) push(bodies, join('--new\n', blocks));
    }
    return strategy_hash(join('--new\n', bodies));
};

export function applied_status(current_hash, state, catalog_hash, empty) {
    if (empty) return 'не выбрана';
    if (state == null || catalog_hash == null) return 'кастомная';
    validate_applied(state);
    let changed = current_hash != state.applied_hash, update = state.applied_hash != catalog_hash;
    if (changed && update) return state.name + ' (изменена вами, есть обновление)';
    if (changed) return state.name + ' (изменена пользователем)';
    return state.name + (update ? ' (доступно обновление)' : '');
};
