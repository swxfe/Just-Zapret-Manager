import { resource } from 'resources';
import { check, read } from 'common';

let general_cleanup = null, general_edges = null;

export function strategy_key(name) {
    if (lc(substr(name || '', 0, 7)) != 'general') return name;
    let separator = substr(name, 7, 1);
    if (length(separator) && index('_.-', separator) == -1) return name;
    if (general_cleanup == null) { general_cleanup = /[^a-z0-9]+/g; general_edges = /^_|_$/g; }
    return replace(replace(lc(name), general_cleanup, '_'), general_edges, '');
};

export function strategy_group(name) {
    if (match(name || '', /^v[0-9]+$/)) return 'base';
    if (match(name || '', /^Yv[0-9]+$/)) return 'youtube';
    if (match(name || '', /^Dv[0-9]+$/)) return 'discord';
    if (match(name || '', /^Gv[0-9]+$/)) return 'games';
    return null;
};

export function strategy_title(name) {
    let key = strategy_key(name);
    if (key == 'general') return 'general (базовый)';
    let alt = match(key || '', /^general_alt([0-9]+)(.*)$/);
    return alt ? 'general (ALT' + alt[1] + replace(alt[2], /_/g, ' ') + ')' : key;
};

export function strategy_order(left, right) {
    let a = strategy_key(left.name), b = strategy_key(right.name);
    if (a == b) return 0;
    if (a == 'general') return -1;
    if (b == 'general') return 1;
    let x = match(a, /^([^0-9]*)([0-9]+)(.*)$/), y = match(b, /^([^0-9]*)([0-9]+)(.*)$/);
    if (x && y && x[1] == y[1] && +x[2] != +y[2]) return +x[2] < +y[2] ? -1 : 1;
    return a < b ? -1 : 1;
};

export function profile_group(block) {
    if (index(block, '--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt') != -1) return 'youtube';
    if (index(block, '--hostlist-domains=discord.media') != -1) return 'discord';
    if (index(block, '--dpi-desync-any-protocol=1') != -1) return 'games';
    if (match(block, /^--filter-tcp=(80,)?443(\n|,)/)) return 'base';
    return null;
};

export function validate_body(body) {
    check(length(body) > 0 && length(body) <= 32768, 'пустая или слишком большая стратегия');
    let lines = [], option_pattern = /^--[A-Za-z0-9][A-Za-z0-9_-]*(=[A-Za-z0-9_.,:\/+=@%{}!~-]+)?$/;
    for (let raw in split(body, '\n')) {
        let line = trim(raw);
        if (!length(line) || substr(line, 0, 1) == '#') continue;
        // Upstream expands NFQWS_OPT as shell words. Reject substitutions and quoting.
        check(match(line, option_pattern),
              'недопустимая строка стратегии: ' + line);
        push(lines, line);
    }
    check(length(lines) > 0 && lines[0] != '--new' && lines[-1] != '--new',
          'пустой блок стратегии');
    for (let i = 1; i < length(lines); i++)
        check(lines[i] != '--new' || lines[i - 1] != '--new', 'соседние --new');
    return join('\n', lines) + '\n';
};

export function strategy_sections(body) {
    let sections = [], label = null, words = [];
    let marker_pattern = /^#([A-Za-z0-9][A-Za-z0-9_.-]*)$/, separators = /[[:space:]]+/;
    for (let raw in split(body || '', '\n')) {
        let line = trim(raw), marker = match(line, marker_pattern);
        if (marker && length(marker[1]) > 64) marker = null;
        if (marker) {
            if (label != null || length(words)) {
                // A delimiter immediately before the next heading joins presets.
                // All other --new tokens remain inside their original preset.
                let separated = words[-1] == '--new';
                if (separated) pop(words);
                push(sections, { label, body: length(words) ? join('\n', words) + '\n' : '', boundary_missing: !separated });
            }
            label = marker[1]; words = [];
            continue;
        }
        line = trim(split(line, '#')[0]);
        if (length(line)) for (let word in split(line, separators)) push(words, word);
    }
    if (label != null || length(words))
        push(sections, { label, body: length(words) ? join('\n', words) + '\n' : '', boundary_missing: false });
    return sections;
};

export function preserve_body(body) {
    let sections = strategy_sections(body), result = [];
    check(length(sections), 'пустая стратегия');
    for (let section in sections) {
        check(!section.boundary_missing, 'между стратегиями требуется --new');
        let normalized = validate_body(section.body);
        push(result, (section.label != null ? '#' + section.label + '\n' : '') + normalized);
    }
    let value = join('--new\n', result);
    check(length(value) <= 32768, 'слишком большая стратегия с метками');
    return value;
};

export function label_strategy(name, body) {
    check(type(name) == 'string' && length(name) <= 64 && match(name, /^[A-Za-z0-9][A-Za-z0-9_.-]*$/), 'неверное имя стратегии');
    return preserve_body('#' + strategy_key(name) + '\n' + validate_body(body));
};

export function parse_catalog(ctx, text, wanted) {
    check(type(text) == 'string' && index(text, '\x00') == -1, 'неверный текст каталога');
    let sections = split('\n' + text, /\n[ \t\r]*#/), result = [], seen = {};
    let name_pattern = /^[A-Za-z0-9][A-Za-z0-9_.-]*$/;
    check(!length(trim(sections[0])), 'стрратегия без заголовка #имя');
    check(length(sections) > 1 && length(sections) - 1 <= ctx.max_strategies, 'лимит числа стратегий');
    // Native splitting visits only preset headers; inactive bodies need no interpreted line scan.
    for (let i = 1; i < length(sections); i++) {
        let section = sections[i], end = index(section, '\n');
        let name = trim(end == -1 ? section : substr(section, 0, end));
        check(length(name) <= 64 && match(name, name_pattern), 'неверное имя стратегии: ' + name);
        check(!seen[name], 'повтор стратегии: ' + name);
        seen[name] = true;
        if (wanted == null || index(wanted, strategy_key(name)) != -1)
            push(result, { name, body: validate_body(end == -1 ? '' : substr(section, end + 1)) });
    }
    return result;
};

export function catalog(ctx, file, wanted) {
    let text = file ? read(file, ctx.max_file_bytes) : resource(ctx.home, 'strategies.txt');
    return parse_catalog(ctx, text, wanted);
};

export function select_strategy(ctx, name, file) {
    let list = catalog(ctx, file, [strategy_key(name)]);
    let found = filter(list, (s) => s.name == name);
    check(length(found) == 1, 'стратегия не найдена: ' + name);
    return found[0];
};

export function compose_bodies(bodies) {
    // nfqws selects the first matching profile: Google must precede broad TCP/443.
    let google = (body) => index(body, '--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt') != -1;
    return preserve_body(join('--new\n', [...filter(bodies, google), ...filter(bodies, (body) => !google(body))]));
};

export function compose(ctx, names, file) {
    check(length(names) > 0, 'укажите имена стратегий');
    let seen = {};
    for (let name in names) { check(!seen[name], 'повтор стратегии: ' + name); seen[name] = true; }
    let list = catalog(ctx, file, map(names, strategy_key));
    return compose_bodies(map(names, (name) => {
        let found = filter(list, (s) => s.name == name);
        check(length(found) == 1, 'стратегия не найдена: ' + name);
        return label_strategy(name, found[0].body);
    }));
};

export function replace_group(current, replacement, group) {
    check(index(['base', 'youtube', 'discord', 'games'], group) != -1, 'неизвестная группа стратегии');
    let keep = [];
    for (let section in strategy_sections(current)) {
        let family = strategy_group(section.label);
        if (family == group) continue;
        if (family != null) {
            push(keep, '#' + section.label + '\n' + validate_body(section.body));
            continue;
        }
        let blocks = [];
        for (let block in split(validate_body(section.body), '--new\n')) {
            let voice = index(block, '--filter-l7=discord,stun') != -1;
            if (profile_group(block) == group || (!length(replacement) && group == 'discord' && voice)) continue;
            push(blocks, block);
        }
        if (length(blocks)) push(keep, (section.label != null ? '#' + section.label + '\n' : '') + join('--new\n', blocks));
    }
    if (length(replacement)) {
        if (group == 'youtube') keep = [preserve_body(replacement), ...keep];
        else push(keep, preserve_body(replacement));
    }
    return length(keep) ? preserve_body(join('--new\n', keep)) : '';
};

export function remove_flowseal(current) {
    let keep = filter(strategy_sections(current), (s) => !match(strategy_key(s.label) || '', /^general(_|$)/));
    return length(keep) ? preserve_body(join('--new\n', map(keep,
        (s) => (s.label != null ? '#' + s.label + '\n' : '') + s.body))) : '';
};
