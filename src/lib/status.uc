import * as fs from 'fs';
import { check, read } from 'common';
import { normalize_options, strategy_hash, read_applied, applied_names, applied_catalog_hash, applied_status } from 'applied';
import { catalog, parse_catalog, strategy_sections, strategy_key, strategy_group, profile_group } from 'strategies';

export function parse_packages(body, format) {
    let result = {};
    for (let record in split(replace(body, /\r/g, '') + '\n\n', /\n\n+/)) {
        if (index(record, 'zapret') == -1) continue;
        let package = match(record, format == 'apk' ? /(^|\n)P:([^\n]+)/ : /(^|\n)Package: *([^\n]+)/);
        if (!package || (package[2] != 'zapret' && package[2] != 'luci-app-zapret')) continue;
        let fields = {};
        for (let line in split(record, '\n')) {
            let m = match(line, /^([^:]+):[ \t]*(.*)$/);
            if (m) fields[m[1]] = m[2];
        }
        let name = fields[format == 'apk' ? 'P' : 'Package'];
        let version = fields[format == 'apk' ? 'V' : 'Version'];
        if (name != 'zapret' && name != 'luci-app-zapret') continue;
        if (format != 'apk' && !match(fields.Status || '', /(^| )installed$/)) continue;
        if (type(version) == 'string' && length(version) <= 100 && match(version, /^[A-Za-z0-9_.+~-]+$/)) result[name] = version;
    }
    return result;
};

export function package_versions(ctx) {
    for (let item in [['/lib/apk/db/installed', 'apk'], ['/usr/lib/opkg/status', 'opkg']]) {
        let path = ctx.root + item[0];
        if (fs.stat(path)) return parse_packages(read(path, 8388608), item[1]);
    }
    return {};
};

export function configured_strategy(ctx) {
    if (!fs.stat(ctx.config)) return '';
    // root accepts neither quotes nor shell metacharacters in settings().
    let uci = "uci -c '" + ctx.root + "/etc/config' -q get ";
    let proc = fs.popen(uci + "'zapret.@main[0].NFQWS_OPT' 2>/dev/null || " +
        uci + "'zapret.@main[0]' >/dev/null 2>&1", 'r');
    check(proc != null, 'не удалось прочитать стратегию UCI');
    let body = '';
    while (true) {
        let chunk = proc.read(4096);
        if (chunk == null || !length(chunk)) break;
        body += chunk;
        if (length(body) > 65536) { proc.close(); die('слишком большая стратегия UCI'); }
    }
    check(proc.close() == 0, 'не удалось прочитать NFQWS_OPT');
    return body;
};

export function normalized_strategy(body) {
    return join('--new\n', map(strategy_sections(body), (section) => section.body));
};

export function inspect_strategy(body, list) {
    let sections = strategy_sections(body), references = [], by_name = {}, overrides = {};
    let wanted = map(sections, (s) => strategy_key(s.label));
    let labelled = length(filter(sections, (s) => s.label == null)) == 0;
    for (let candidate in list) {
        let name = strategy_key(candidate.name);
        if (by_name[name] || (labelled && index(wanted, name) == -1)) continue;
        let ref = { name, body: normalized_strategy(candidate.body) };
        by_name[name] = ref; push(references, ref);
    }
    // A named replacement accounts for precisely the profiles removed by the editor.
    // Arbitrary changes to the remaining Flowseal parameters still fail comparison.
    for (let section in sections) {
        let name = strategy_key(section.label), ref = by_name[name], group = strategy_group(name);
        if (group && ref && ref.body == section.body && !section.boundary_missing) overrides[group] = true;
    }
    let result = [];
    for (let section in sections) {
        if (section.label != null) {
            let name = strategy_key(section.label), ref = by_name[name];
            let exact = ref && ref.body == section.body;
            if (!exact && ref && match(name, /^general(_|$)/)) {
                let remaining = filter(split(ref.body, '--new\n'), (block) => !overrides[profile_group(block)]);
                exact = join('--new\n', remaining) == section.body;
            }
            push(result, { name, body: section.body, changed: !exact || section.boundary_missing });
            continue;
        }
        // Legacy configs: match complete consecutive presets, preferring the longest.
        let blocks = split(section.body, '--new\n');
        for (let i = 0; i < length(blocks);) {
            let found = null, count = 0;
            for (let ref in references) {
                let parts = split(ref.body, '--new\n');
                if (!length(ref.body) || length(parts) <= count || i + length(parts) > length(blocks)) continue;
                if (join('--new\n', slice(blocks, i, i + length(parts))) == ref.body) { found = ref; count = length(parts); }
            }
            push(result, { name: found ? found.name : null,
                body: join('--new\n', slice(blocks, i, i + (found ? count : 1))), changed: false });
            i += found ? count : 1;
        }
    }
    return result;
};

export function strategy_summary(sections) {
    if (!length(sections)) return 'не выбрана';
    if (!length(filter(sections, (s) => s.name != null))) return 'кастомная';
    return join(' + ', map(sections, (s) => s.name == null ? 'кастомный блок' : s.name + (s.changed ? ' (изменена)' : '')));
};

export function identify_strategy(body, list, state) {
    if (!length(normalize_options(body))) return 'не выбрана';
    if (state == null) return 'кастомная';
    return applied_status(strategy_hash(body), state, applied_catalog_hash(state, list), false);
};

export function reference_catalog(ctx, wanted) {
    let list = [];
    for (let kind in ['flowseal', 'manager']) {
        let path = ctx.state + '/' + kind + '.json';
        if (!fs.stat(path)) continue;
        try { list = [...list, ...parse_catalog(ctx, json(read(path, ctx.max_file_bytes)).catalog, wanted)]; }
        catch (e) { /* Invalid cached presets cannot hide the actual configuration. */ }
    }
    return [...list, ...catalog(ctx, null, wanted)];
};

export function strategy_state(ctx, summary_only) {
    let body = configured_strategy(ctx), state = null;
    if (!length(normalize_options(body))) return { summary: 'не выбрана', sections: [] };
    try { state = read_applied(ctx); } catch (e) { /* An invalid baseline cannot establish provenance. */ }
    if (summary_only) {
        let names = applied_names(state);
        let list = length(filter(names, (name) => name != null)) ? reference_catalog(ctx, names) : [];
        return { summary: identify_strategy(body, list, state), sections: [] };
    }
    let raw = strategy_sections(body);
    let wanted = length(filter(raw, (s) => s.label == null)) ? null :
        [...map(raw, (s) => strategy_key(s.label)), ...applied_names(state)];
    let list = reference_catalog(ctx, wanted);
    return { summary: identify_strategy(body, list, state), sections: inspect_strategy(body, list) };
};

export function group_state(sections, group) {
    let names = [];
    for (let section in sections) {
        let family = strategy_group(section.name);
        let belongs = family == group;
        if (family == null) {
            belongs = length(filter(split(section.body, '--new\n'), (block) => profile_group(block) == group ||
                (group == 'discord' && index(block, '--filter-l7=discord,stun') != -1))) > 0;
        }
        if (belongs) push(names, section.name == null ? 'кастомный блок' : section.name + (section.changed ? ' (изменена)' : ''));
    }
    return length(names) ? join(' + ', names) : '[отключено]';
};

export function procd_running(reply) {
    check(type(reply) == 'object', 'неверный ответ procd');
    if (reply.zapret == null) return false;
    check(type(reply.zapret.instances) == 'object', 'procd не вернул экземпляры Zapret');
    for (let key, instance in reply.zapret.instances) if (instance.running == true) return true;
    return false;
};

export function service_running(ctx) {
    let ubus = ctx.root + '/bin/ubus';
    if (fs.stat(ubus)) {
        let proc = fs.popen("'" + ubus + "' -t 1 call service list '{\"name\":\"zapret\"}' 2>/dev/null", 'r');
        if (proc == null) return null;
        let reply = proc.read(65537), rc = proc.close();
        if (rc != 0 || reply == null || length(reply) > 65536) return null;
        try { return procd_running(json(reply)); } catch (e) { return null; }
    }
    let init = ctx.root + '/etc/init.d/zapret';
    return fs.stat(init) != null && system(['/bin/sh', '-c',
        'exec "$1" running >/dev/null 2>&1', 'jzm-status', init]) == 0;
};

export function zapret_status(ctx) {
    let versions = package_versions(ctx), init = ctx.root + '/etc/init.d/zapret';
    let installed = versions.zapret != null || (fs.stat(init) != null && fs.stat(ctx.config) != null);
    let running = installed ? service_running(ctx) : false;
    let strategy = 'не выбрана';
    if (installed) {
        try { strategy = strategy_state(ctx, true).summary; }
        catch (e) { strategy = 'не удалось прочитать: ' + e.message; }
    }
    return { installed, running, version: versions.zapret || (installed ? 'неизвестна (без записи пакета)' : '—'),
        luci: versions['luci-app-zapret'] || null, strategy };
};

export function release_compare(a, b) {
    let left = match(a, /^v?([0-9]+(\.[0-9]+)*)(-r[0-9]+)?$/);
    let right = match(b, /^v?([0-9]+(\.[0-9]+)*)(-r[0-9]+)?$/);
    check(left && right, 'не удалось сравнить версии Zapret; автоматическая переустановка отменена');
    left = split(left[1], '.'); right = split(right[1], '.');
    for (let i = 0; i < length(left) || i < length(right); i++) {
        let x = +(left[i] || 0), y = +(right[i] || 0);
        if (x != y) return x > y ? 1 : -1;
    }
    return 0;
};

export function release_plan(versions, latest) {
    let core = versions.zapret, luci = versions['luci-app-zapret'];
    if (!core || release_compare(core, latest) < 0) return 'both';
    if (!luci || release_compare(luci, latest) < 0) {
        check(release_compare(core, latest) == 0, 'установлен более новый Zapret; подходящий LuCI отсутствует в этом релизе');
        return 'luci';
    }
    return 'none';
};
