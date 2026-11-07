import * as fs from 'fs';
import { check } from 'common';
import { installed_assets, fake_filename } from 'assets';
import { preserve_body } from 'strategies';
import { configured_strategy } from 'status';

export function fake_catalog(ctx, kind) {
    check(kind == 'flowseal', 'неизвестный источник');
    return sort(map(filter(installed_assets(ctx).fakes, (entry) => entry.source == kind &&
        fs.stat(ctx.root + entry.path)?.type == 'file'), (entry) => entry.name));
};

// Canonicalizing first also handles UCI configurations written on one line.
export function fake_slots(body) {
    if (!length(trim(body || ''))) return [];
    let slots = [], section = 'своя стратегия', profile = 1, global_profile = 1;
    let lines = split(preserve_body(body), '\n');
    for (let i = 0; i < length(lines); i++) {
        let line = lines[i];
        if (substr(line, 0, 1) == '#') { section = substr(line, 1); profile = 1; }
        if (line == '--new') { profile++; global_profile++; }
        let m = match(line, /^(--dpi-desync-[A-Za-z0-9_-]+)=(\/opt\/zapret\/(fakes|files\/fake)\/([A-Za-z0-9_][A-Za-z0-9_.-]*\.bin))$/);
        if (m && match(m[1], /^--dpi-desync-(fake-[A-Za-z0-9_-]+|[A-Za-z0-9_-]+-pattern)$/)) push(slots, { line: i, option: m[1], path: m[2], name: m[4], section, profile, global_profile });
    }
    return slots;
};

export function current_fakes(ctx) {
    let entries = [];
    try { entries = installed_assets(ctx).fakes; } catch (e) { /* Unmanaged files remain visible. */ }
    let by_path = {};
    for (let entry in entries) by_path[entry.path] = entry;
    return map(fake_slots(configured_strategy(ctx)), (slot) => {
        let entry = by_path[slot.path], st = fs.stat(ctx.root + slot.path);
        return { ...slot, present: st?.type == 'file' && st.size > 0,
            source: entry?.source || 'не указан', filename: entry?.name || slot.name };
    });
};

// Group by full path: equal basenames in different directories are distinct files.
export function group_fakes(slots) {
    let groups = [], by_path = {};
    for (let slot in slots) {
        if (by_path[slot.path] == null) {
            by_path[slot.path] = length(groups);
            push(groups, { path: slot.path, filename: slot.filename || slot.name,
                present: slot.present, source: slot.source, sections: [], slots: [] });
        }
        let group = groups[by_path[slot.path]];
        push(group.slots, slot);
        if (index(group.sections, slot.section) == -1) push(group.sections, slot.section);
    }
    return groups;
};

export function replace_fake(body, line, expected, path) {
    check(type(line) == 'string' && match(line, /^[0-9]+$/), 'неверный номер фейка');
    let slot = filter(fake_slots(body), (s) => s.line == +line && s.path == expected)[0];
    check(slot != null, 'фейк уже изменён; откройте меню заново');
    check(match(path, /^\/opt\/zapret\/(fakes|files\/fake)\/[A-Za-z0-9_][A-Za-z0-9_.-]*\.bin$/), 'неверный путь фейка');
    let lines = split(preserve_body(body), '\n');
    lines[slot.line] = slot.option + '=' + path;
    return preserve_body(join('\n', lines));
};

export function prepare_fake_replacement(ctx, line, expected, kind, name) {
    check(kind == 'flowseal', 'неизвестный источник');
    let body = configured_strategy(ctx);
    replace_fake(body, line, expected, expected);
    fake_filename(name);
    let selected = filter(installed_assets(ctx).fakes, (entry) => entry.source == kind && entry.name == name);
    check(length(selected) == 1, 'фейк отсутствует в установленных ассетах');
    let target = selected[0].path, st = fs.stat(ctx.root + target);
    check(st?.type == 'file' && st.size > 0, 'файл ассета отсутствует; переустановите архив ассетов');
    return replace_fake(body, line, expected, target);
};
