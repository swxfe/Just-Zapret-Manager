import { current_fakes, prepare_fake_replacement } from 'fakes';
import { check_update, cache_update, install_manager, apply_update } from 'manager';
import { resource, VERSION } from 'resources';
import * as fs from 'fs';
import { check, read, backend, run, output, send, target_text } from 'common';
import { settings } from 'settings';
import { cached, invalidate } from 'cache';
import { catalog, compose, compose_bodies, preserve_body, label_strategy, replace_group, remove_flowseal, strategy_key, strategy_group, strategy_sections } from 'strategies';
import { domains, urls, validate_list_snapshot } from 'domains';
import { source_data } from 'sources';
import { release_install } from 'releases';
import { install_assets } from 'assets';
import { excluded, exclusion_hook, ipv4, device_list, legacy_exclusions } from 'devices';
import { package_versions, configured_strategy, inspect_strategy, reference_catalog, service_running } from 'status';
import { strategy_hash, read_applied, create_applied, validate_applied } from 'applied';

const HELP = 'Внутренний протокол JZM. Пользовательский запуск: jzm\n';

function arity(args, min, max) {
    check(length(args) >= min && length(args) <= max, 'неверное число аргументов; см. help');
}

function same_content(path, body) {
    let st = fs.stat(path);
    return st != null && st.type == 'file' && st.size == length(body) && fs.readfile(path, st.size + 1) == body;
}

function editable(ctx, key, value) {
    let booleans = ['DISABLE_IPV6', 'DISABLE_CUSTOM', 'ENABLED', 'DEBUG'];
    let ports = ['NFQWS_PORTS_TCP', 'NFQWS_PORTS_UDP'];
    if (index(booleans, key) != -1) check(value == '0' || value == '1', 'ожидается 0 или 1');
    else if (index(ports, key) != -1) {
        for (let range in split(value, ',')) {
            check(match(range, /^[0-9]{1,5}(-[0-9]{1,5})?$/), 'неверный диапазон портов');
            let pair = split(range, '-');
            check(+pair[0] >= 1 && +pair[0] <= 65535 &&
                  (length(pair) == 1 || (+pair[1] >= +pair[0] && +pair[1] <= 65535)), 'порт вне диапазона');
        }
    }
    else if (key == 'MODE_FILTER')
        check(index(['none', 'hostlist', 'autohostlist', 'ipset'], value) != -1, 'неверный MODE_FILTER');
    else die('изменение этой опции не поддерживается: ' + key);
}

function dependencies(ctx, body) {
    // The upstream init script expands arguments; paths must exist before config is changed.
    let path_pattern = /^--[^=]+=(\/[^,]+)$/;
    for (let line in split(body, '\n')) {
        let m = match(line, path_pattern);
        if (m) check(fs.stat(ctx.root + m[1])?.type == 'file', 'не найден файл стратегии: ' + m[1]);
    }
}

function persist_applied(ctx, body) {
    let raw = strategy_sections(body);
    let wanted = length(filter(raw, (s) => s.label == null)) ? null : map(raw, (s) => strategy_key(s.label));
    let list = reference_catalog(ctx, wanted);
    let state = create_applied(body, inspect_strategy(body, list), list, time());
    send(ctx, 'state-write', ['state.json'], sprintf('%J\n', state));
}

function approve_strategy_change(ctx, clearing) {
    let state = read_applied(ctx);
    if (state == null || strategy_hash(configured_strategy(ctx)) == state.applied_hash) return true;
    print(clearing ? 'Внимание: ваши ручные изменения будут удалены. Продолжить? [y/N] ' :
        'Внимание: ваши ручные изменения будут заменены версией из каталога. Продолжить? [y/N] ');
    fs.stdout.flush();
    let answer = '';
    while (true) {
        let c = fs.stdin.read(1);
        if (c == null || !length(c)) return false;
        if (c == '\n') break;
        if (c != '\r') answer += c;
        check(length(answer) <= 4096, 'слишком длинное подтверждение');
    }
    return lc(trim(answer)) == 'y';
}

function apply(ctx, body, transient) {
    if (!length(trim(body))) {
        run(ctx, 'config-set', ['NFQWS_OPT', '', 'NFQWS_ENABLE', '0']);
        run(ctx, 'service', ['stop']);
        if (!transient) persist_applied(ctx, '');
        return;
    }
    body = preserve_body(body);
    dependencies(ctx, body);
    let updates = [];
    for (let proto in ['TCP', 'UDP']) {
        let option = 'NFQWS_PORTS_' + proto;
        let ports = trim(output(ctx, 'config-get-optional', [option]));
        let previous = ports, seen_ports = {};
        let items = [];
        for (let port in (length(ports) ? split(ports, ',') : []))
            if (!exists(seen_ports, port)) { seen_ports[port] = true; push(items, port); }
        let filter_pattern = regexp('^--filter-' + lc(proto) + '=([0-9,-]+)$');
        for (let line in split(body, '\n')) {
            let m = match(line, filter_pattern);
            if (m) for (let port in split(m[1], ',')) if (!exists(seen_ports, port)) { seen_ports[port] = true; push(items, port); }
        }
        if (length(items)) {
            ports = join(',', items);
            editable(ctx, option, ports);
            if (ports != previous) push(updates, option, ports);
        }
    }
    if (!length(updates) && trim(configured_strategy(ctx)) == trim(body) &&
        replace(output(ctx, 'config-get-optional', ['NFQWS_ENABLE']), /\n$/, '') == '1' && service_running(ctx) == true) {
        if (!transient) persist_applied(ctx, body);
        return;
    }
    run(ctx, 'config-set', [...updates, 'NFQWS_OPT', body, 'NFQWS_ENABLE', '1']);
    run(ctx, 'service', ['restart']);
    if (!transient) persist_applied(ctx, body);
}

function initialize_lists(ctx) {
    for (let kind in ['user', 'exclude', 'google']) {
        let name = kind == 'user' ? 'zapret-hosts-user.txt' :
            (kind == 'exclude' ? 'zapret-hosts-user-exclude.txt' : 'zapret-hosts-google.txt');
        if (fs.stat(ctx.base + '/ipset/' + name)) continue;
        let body = resource(ctx.resources, kind + '.txt');
        send(ctx, 'hosts-write', [kind], body);
    }
}

function probe(ctx, targets) {
    let ok = 0;
    for (let url in targets) {
        let rc = backend(ctx, 'probe', [ctx.connect_timeout, ctx.request_timeout, url]);
        printf('%s %s\n', rc == 0 ? 'OK' : 'FAIL', url);
        if (rc == 0) ok++;
    }
    return ok;
}

function benchmark(ctx, args, keep, prepared) {
    arity(args, 1, 2);
    let targets = urls(target_text(ctx, args[0]), ctx.max_urls);
    let list = [], results = [];
    for (let s in (prepared?.strategies || catalog(ctx, args[1]))) {
        try { dependencies(ctx, s.body); push(list, s); }
        catch (e) { push(results, { name: s.name, skipped: e.message }); }
    }
    check(length(list) > 0, 'нет стратегий с доступными файлами');
    run(ctx, 'service', ['stop']);
    run(ctx, 'settle', [ctx.settle_seconds]);
    let control = probe(ctx, targets), best = null;
    for (let s in list) {
        run(ctx, 'reset-config');
        apply(ctx, label_strategy(s.name, s.body), true);
        run(ctx, 'settle', [ctx.settle_seconds]);
        let score = probe(ctx, targets);
        let row = { name: s.name, ok: score, total: length(targets) };
        push(results, row);
        if (best == null || score > best.ok) best = row;
    }
    run(ctx, 'reset');
    let applied = keep && best.ok > control;
    if (applied) {
        let body = label_strategy(best.name, filter(list, (s) => s.name == best.name)[0].body);
        initialize_lists(ctx);
        apply(ctx, body);
    }
    printf('%J\n', { control, total: length(targets), results, best, applied });
}

function host_command(ctx, args) {
    arity(args, 2, ctx.max_domains + 2);
    let kind = args[0], action = args[1], extra = slice(args, 2);
    check(index(['user', 'exclude', 'google'], kind) != -1, 'неверный список доменов');
    if (action == 'show') {
        arity(extra, 0, 0);
        print(output(ctx, 'hosts-read', [kind]));
        return;
    }
    let items;
    if (action == 'replace') {
        arity(extra, 1, 1);
        items = domains(read(extra[0], ctx.max_file_bytes), ctx.max_domains);
    }
    else if (action == 'refresh') {
        arity(extra, 0, 0);
        let text = resource(ctx.resources, kind + '.txt');
        validate_list_snapshot(text, ctx.max_domains, ctx.max_file_bytes);
        send(ctx, 'hosts-write', [kind], text);
        run(ctx, 'service', ['restart']);
        return;
    }
    else {
        check(action == 'add' || action == 'remove', 'неизвестная операция со списком');
        arity(extra, 1, ctx.max_domains);
        let old = domains(output(ctx, 'hosts-read', [kind]), ctx.max_domains);
        let change = domains(join('\n', extra), ctx.max_domains);
        let names = {};
        if (action == 'add') {
            for (let name in old) names[name] = true;
            for (let name in change) names[name] = true;
            check(length(names) <= ctx.max_domains, 'превышен лимит доменов');
            items = sort(keys(names));
        }
        else {
            for (let name in change) names[name] = true;
            items = filter(old, (name) => !exists(names, name));
        }
    }
    let body = length(items) ? join('\n', items) + '\n' : '';
    check(length(body) <= ctx.max_file_bytes, 'список превышает лимит размера');
    send(ctx, 'hosts-write', [kind], body);
    run(ctx, 'service', ['restart']);
}

function backup(ctx, args) {
    arity(args, 2, 2);
    if (args[0] == 'save') {
        let lists = {};
        for (let kind in ['user', 'exclude', 'google']) {
            lists[kind] = output(ctx, 'hosts-read', [kind]);
            validate_list_snapshot(lists[kind], ctx.max_domains, ctx.max_file_bytes);
        }
        let data = { format: 1, profile: ctx.profile, config: read(ctx.config, ctx.max_file_bytes), lists,
                     devices: excluded(ctx), strategy_state: read_applied(ctx) };
        let text = sprintf('%J\n', data);
        check(length(text) <= ctx.max_file_bytes, 'резервная копия превышает max_file_bytes');
        send(ctx, 'backup-write', [args[1]], text);
    }
    else {
        check(args[0] == 'restore', 'backup: save или restore');
        let data = json(read(args[1], ctx.max_file_bytes));
        check(data.format == 1 && data.profile == ctx.profile && type(data.config) == 'string' &&
              type(data.lists) == 'object', 'неверный формат/профиль резервной копии');
        if (data.strategy_state != null) validate_applied(data.strategy_state);
        // Validate the complete document before the first write.
        for (let kind, value in data.lists) {
            check(index(ctx.profile == 'zapret' ? ['user', 'exclude', 'google'] : ['user', 'exclude'], kind) != -1 &&
                  type(value) == 'string', 'неверный список в резервной копии');
            validate_list_snapshot(value, ctx.max_domains, ctx.max_file_bytes);
        }
        if (data.devices != null) {
            check(type(data.devices) == 'array' && length(data.devices) <= 256, 'неверный список устройств в копии');
            for (let ip in data.devices) ipv4(ip);
        }
        let restart = !same_content(ctx.config, data.config);
        for (let kind, value in data.lists) {
            let name = kind == 'user' ? 'zapret-hosts-user.txt' :
                (kind == 'exclude' ? 'zapret-hosts-user-exclude.txt' : 'zapret-hosts-google.txt');
            if (!same_content(ctx.base + '/ipset/' + name, value)) restart = true;
        }
        let hook = data.devices != null ? exclusion_hook(ctx, data.devices) : null;
        let hook_file = ctx.base + '/init.d/openwrt/custom.d/20-jzm-exclude.sh';
        let hook_changed = hook != null && (legacy_exclusions(ctx) != null ||
            !same_content(hook_file, hook) || ((fs.stat(hook_file)?.mode || 0) & 0777) != 0755);
        if (hook_changed) restart = true;
        send(ctx, 'config-restore', [], data.config);
        if (data.strategy_state != null) {
            let saved = sprintf('%J\n', data.strategy_state);
            if (!same_content(ctx.state + '/state.json', saved)) send(ctx, 'state-write', ['state.json'], saved);
        }
        else run(ctx, 'strategy-state-clear');
        for (let kind, value in data.lists) {
            let name = kind == 'user' ? 'zapret-hosts-user.txt' :
                (kind == 'exclude' ? 'zapret-hosts-user-exclude.txt' : 'zapret-hosts-google.txt');
            if (!same_content(ctx.base + '/ipset/' + name, value)) send(ctx, 'hosts-write', [kind], value);
        }
        if (data.devices != null) {
            if (hook_changed) send(ctx, 'device-hook-write', legacy_exclusions(ctx) != null ? ['migrate'] : [], hook);
            let devices_body = length(data.devices) ? join('\n', data.devices) + '\n' : '';
            if (!same_content(ctx.state + '/devices.txt', devices_body)) send(ctx, 'state-write', ['devices.txt'], devices_body);
        }
        if (restart || service_running(ctx) != true) run(ctx, 'service', ['restart']);
    }
}

function dispatch(ctx, command, args) {
    let changes_strategy = (command == 'strategy' && index(['apply', 'import', 'clear'], args[0]) != -1) ||
        (command == 'source' && index(['apply', 'compose', 'group', 'remove', 'benchmark', 'auto-best'], args[0]) != -1) ||
        command == 'benchmark' || command == 'auto-best';
    // Run after acquiring the transaction lock, before downloads or configuration writes.
    if (changes_strategy && !approve_strategy_change(ctx, command == 'strategy' && args[0] == 'clear')) { print('\nДействие отменено.\n'); return; }
    switch (command) {
    case 'backend-operation': {
        let action = args[0], values = slice(args, 3);
        if (index(['state-write', 'hosts-write', 'config-restore', 'device-hook-write',
                   'manager-config-init', 'backup-write'], action) != -1) {
            check(length(values), 'не указан файл операции');
            send(ctx, action, slice(values, 1), read(values[0], ctx.max_file_bytes));
        }
        else if (action == 'config-read' || action == 'config-read-optional')
            print(output(ctx, action == 'config-read' ? 'config-get' : 'config-get-optional', values));
        else if (action == 'hosts-read-stdout') print(output(ctx, 'hosts-read', values));
        else {
            check(index(['config-set', 'service', 'network', 'asset-file', 'manager-install',
                'manager-uninstall', 'strategy-state-clear', 'schedule', 'uninstall-cleanup', 'status', 'doctor', 'settle'], action) != -1,
                'неизвестная нативная операция: ' + action);
            run(ctx, action, values);
        }
        break;
    }
    case 'uninstall':
        arity(args, 1, 1);
        check(args[0] == 'manager', 'полное удаление выполняется через пакетную фазу');
        run(ctx, 'uninstall-cleanup', args);
        break;
    case 'uninstall-finish':
        arity(args, 1, 1);
        check(args[0] == 'all', 'неверный режим удаления');
        run(ctx, 'uninstall-cleanup', args);
        break;
    case 'assets-install':
        arity(args, 1, 1);
        install_assets(ctx, args[0]);
        break;
    case 'manager-install':
        arity(args, 0, 1);
        install_manager(ctx, args[0]);
        break;
    case 'manager-uninstall':
        arity(args, 0, 0);
        run(ctx, 'manager-uninstall');
        break;
    case 'manager-update':
        arity(args, 0, 0);
        apply_update(ctx);
        break;
    case 'manager-check':
        arity(args, 0, 0);
        check_update(ctx);
        break;
    case 'manager-cache':
        arity(args, 1, 1);
        cache_update(ctx, json(args[0]));
        break;
    case 'network':
        arity(args, 1, 2);
        run(ctx, 'network', args);
        break;
    case 'blockcheck':
        arity(args, 0, 0);
        run(ctx, 'blockcheck');
        break;
    case 'devices': {
        arity(args, 1, 2);
        let current = excluded(ctx);
        if (args[0] == 'list') {
            for (let item in device_list(ctx)) printf('%s %s %s\n', index(current, item.ip) == -1 ? 'Zapret' : 'Исключён', item.ip, item.name);
            break;
        }
        if (args[0] == 'clear') { arity(args, 1, 1); current = []; }
        else {
            check(index(['toggle', 'add', 'remove'], args[0]) != -1, 'неверная команда исключений'); arity(args, 2, 2);
            let ip = ipv4(args[1]);
            let present = index(current, ip) != -1;
            if (args[0] == 'add' && present || args[0] == 'remove' && !present) break;
            if (args[0] == 'add' || args[0] == 'toggle' && !present) push(current, ip);
            else current = filter(current, (item) => item != ip);
        }
        check(fs.stat(ctx.config), 'Zapret не установлен');
        send(ctx, 'device-hook-write', legacy_exclusions(ctx) != null ? ['migrate'] : [], exclusion_hook(ctx, current));
        send(ctx, 'state-write', ['devices.txt'], length(current) ? join('\n', sort(current)) + '\n' : '');
        run(ctx, 'config-set', ['DISABLE_CUSTOM', '0']);
        run(ctx, 'service', ['restart']);
        break;
    }
    case 'package-configure':
        arity(args, 1, 1);
        check(args[0] == 'enable' || args[0] == 'keep', 'неверный режим конфигурации пакета');
        initialize_lists(ctx);
        if (args[0] == 'enable') run(ctx, 'service', ['enable']);
        run(ctx, 'service', ['restart']);
        break;
    case 'fake':
        arity(args, 1, 5);
        if (args[0] == 'list') {
            arity(args, 1, 1);
            printf('%J\n', current_fakes(ctx));
        }
        else {
            check(args[0] == 'replace', 'неверная команда фейков');
            arity(args, 5, 5);
            let body = prepare_fake_replacement(ctx, args[1], args[2], args[3], args[4]);
            if (trim(body) != trim(configured_strategy(ctx))) apply(ctx, body);
        }
        break;
    case 'source': {
        arity(args, 2, 10);
        let action = args[0], kind = args[1];
        check(kind == 'flowseal' || kind == 'manager', 'неизвестный источник');
        if (action == 'remove') {
            arity(args, kind == 'manager' ? 3 : 2, 3);
            let current = output(ctx, 'config-get-optional', ['NFQWS_OPT']);
            apply(ctx, length(args) == 3 ? replace_group(current, '', args[2]) : remove_flowseal(current));
            break;
        }
        let wanted = index(['show', 'apply', 'compose', 'group'], action) != -1 ?
            map(slice(args, action == 'group' ? 3 : 2), strategy_key) : null;
        let data = source_data(ctx, kind, wanted), list = data.strategies;
        if (action == 'list') { for (let s in list) printf('%s\n', s.name); break; }
        if (action == 'show' || action == 'apply' || action == 'compose' || action == 'group') {
            arity(args, action == 'group' ? 4 : 3, action == 'compose' ? 10 : (action == 'group' ? 4 : 3));
            let selected = [], seen = {};
            for (let name in slice(args, action == 'group' ? 3 : 2)) {
                check(!seen[name], 'повтор стратегии: ' + name);
                seen[name] = true;
                let found = filter(list, (s) => strategy_key(s.name) == strategy_key(name));
                check(length(found) == 1, 'стратегия не найдена: ' + name);
                push(selected, label_strategy(name, found[0].body));
            }
            let body = action == 'compose' ? compose_bodies(selected) : join('--new\n', selected);
            if (action == 'group') {
                check(strategy_group(slice(args, 3)[0]) == args[2], 'стратегия не относится к выбранной группе');
                body = replace_group(output(ctx, 'config-get-optional', ['NFQWS_OPT']), body, args[2]);
            }
            if (action == 'show') print(body);
            else {
                check(ctx.profile == 'zapret' && fs.stat(ctx.config), 'сначала установите Zapret');
                initialize_lists(ctx);
                apply(ctx, body);
            }
            break;
        }
        if (action == 'export') {
            arity(args, 3, 3);
            check(match(args[2], /^[A-Za-z0-9_-]+\.txt$/), 'неверное имя файла каталога');
            send(ctx, 'state-write', [args[2]], join('', map(filter(list, (s) => (kind == 'manager' || strategy_group(s.name) == null)),
                (s) => '#' + s.name + '\n' + s.body)));
            break;
        }
        check(action == 'benchmark' || action == 'auto-best', 'неизвестное действие источника');
        arity(args, 3, 3);
        initialize_lists(ctx);
        benchmark(ctx, [args[2]], action == 'auto-best', { ...data, strategies: filter(list, (s) => (kind == 'manager' || strategy_group(s.name) == null)) });
        break;
    }
    case 'status': case 'doctor': case 'recover':
        arity(args, 0, 0);
        run(ctx, command);
        break;
    case 'service':
        arity(args, 1, 1);
        check(index(['start', 'stop', 'restart', 'enable', 'disable'], args[0]) != -1, 'неизвестная команда сервиса');
        run(ctx, 'service', args);
        break;
    case 'config':
        arity(args, 1, 3);
        if (args[0] == 'show') { arity(args, 1, 1); print(cached(ctx, 'config-body', () => read(ctx.config, ctx.max_file_bytes))); }
        else if (args[0] == 'get') {
            arity(args, 2, 2);
            check(match(args[1], /^[A-Za-z][A-Za-z0-9_]*$/), 'неверное имя опции');
            print(output(ctx, 'config-get', [args[1]]));
        }
        else {
            check(args[0] == 'set', 'config: show/get/set'); arity(args, 3, 3);
            editable(ctx, args[1], args[2]);
            let current = replace(output(ctx, 'config-get-optional', [args[1]]), /\n$/, '');
            if (current == args[2]) break;
            run(ctx, 'config-set', slice(args, 1));
            run(ctx, 'service', ['restart']);
        }
        break;
    case 'strategy':
        check(length(args) > 0, 'strategy: list/show/apply/import/validate/clear');
        if (args[0] == 'clear') {
            arity(args, 1, 1);
            check(fs.stat(ctx.config), 'Zapret не установлен');
            if (length(trim(configured_strategy(ctx))) ||
                trim(output(ctx, 'config-get-optional', ['NFQWS_ENABLE'])) != '0' || service_running(ctx) != false)
                apply(ctx, '');
            else if (read_applied(ctx)?.applied_hash != strategy_hash('')) persist_applied(ctx, '');
        }
        else if (args[0] == 'list') {
            arity(args, 1, 2);
            for (let s in catalog(ctx, args[1])) printf('%s\n', s.name);
        }
        else if (args[0] == 'validate' || args[0] == 'import') {
            arity(args, 2, 2);
            let body = preserve_body(read(args[1], ctx.max_file_bytes));
            if (args[0] == 'validate') print(body); else apply(ctx, body);
        }
        else {
            check(args[0] == 'show' || args[0] == 'apply', 'неизвестная операция стратегии');
            arity(args, 2, args[0] == 'show' ? 2 : ctx.max_strategies);
            let body = compose(ctx, slice(args, 1));
            if (args[0] == 'show') print(body); else apply(ctx, body);
        }
        break;
    case 'hosts': host_command(ctx, args); break;
    case 'targets':
        arity(args, 1, 1);
        urls(target_text(ctx, args[0]), ctx.max_urls);
        send(ctx, 'state-write', ['urls.txt'], target_text(ctx, args[0]));
        break;
    case 'backup': backup(ctx, args); break;
    case 'test': {
        arity(args, 1, 1);
        let targets = urls(target_text(ctx, args[0]), ctx.max_urls);
        let ok = probe(ctx, targets);
        printf('%J\n', { ok, total: length(targets) });
        check(ok == length(targets), 'часть URL недоступна');
        break;
    }
    case 'benchmark': case 'auto-best': benchmark(ctx, args, command == 'auto-best'); break;
    case 'schedule':
        arity(args, 1, 3);
        if (args[0] == 'off') arity(args, 1, 1);
        else {
            check(match(args[0], /^([0-9]|1[0-9]|2[0-3])$/), 'час: 0..23');
            arity(args, 2, 3);
            urls(read(args[1], ctx.max_file_bytes), ctx.max_urls);
            if (args[2]) catalog(ctx, args[2]);
        }
        if (args[0] != 'off' && length(args) == 2) {
            send(ctx, 'state-write', ['scheduled.txt'], resource(ctx.resources, 'strategies.txt'));
            push(args, ctx.state + '/scheduled.txt');
        }
        run(ctx, 'schedule', [ctx.file, ...args]);
        break;
    default: die('неизвестная команда: ' + command);
    }
}

function package_phase(ctx, command, args) {
    check(!getenv('ZM_TRANSACTION'), 'пакетная операция внутри транзакции запрещена');
    let mode = null;
    if (command == 'install-upstream' || command == 'update-upstream') {
        arity(args, 0, 0);
        let plan = release_install({ ...ctx, cache: null });
        if (plan != 'none') invalidate(ctx);
        if (plan == 'both') mode = 'enable';
    }
    else {
        if (command == 'remove') arity(args, 0, 0);
        for (let file in args) {
            check(match(fs.basename(file), /^(luci-app-)?zapret[_-][A-Za-z0-9_.+-]+\.(ipk|apk)$/), 'ожидается локальный пакет Zapret: ' + file);
            check(fs.stat(file)?.type == 'file', 'пакет не найден: ' + file);
        }
        let before_versions = package_versions({ ...ctx, cache: null });
        let before = before_versions.zapret;
        run(ctx, 'package', [command, ...args]);
        let after_versions = package_versions({ ...ctx, cache: null });
        let after = after_versions.zapret;
        if (sprintf('%J', before_versions) != sprintf('%J', after_versions)) invalidate(ctx);
        if (command != 'remove' && after && after != before) mode = before ? 'keep' : 'enable';
    }
    if (mode == null) return 0;
    let argv = [...(fs.stat(ctx.file) ? ['--config', ctx.file] : []), 'package-configure', mode];
    return backend(ctx, 'transaction', argv) == 0 ? 0 : 1;
}

export function command_main(argv, session) {
try {
    // ucode defers handlers until a synchronous helper has finished. The supervisor
    // waits for that worker before restoring files, so helpers cannot race the rollback.
    for (let name in ['SIGINT', 'SIGTERM', 'SIGHUP'])
        signal(name, () => die('операция прервана'));
    let args = [...argv], file = null;
    while (length(args) && substr(args[0], 0, 2) == '--') {
        let flag = shift(args);
        if (flag == '--help') { print(HELP); return 0; }
        check(flag == '--config', 'неизвестный параметр: ' + flag);
        check(length(args), 'не задано значение ' + flag);
        file = shift(args);
    }
    let command = shift(args) || 'help';
    if (command == 'help') { print(HELP); return 0; }
    if (command == 'version') { print(VERSION + '\n'); return 0; }
    let ctx = session && (file == null || file == session.file) ? session : settings(getenv('ZM_HOME'), file);
    if (command == 'backend-operation') {
        arity(args, 3, 1024);
        check(args[2] == 'zapret' && type(args[1]) == 'string' &&
            (args[1] == '' || match(args[1], /^\/([A-Za-z0-9_. -]+\/)*[A-Za-z0-9_. -]*$/)) &&
            !match(args[1], /(^|\/)\.\.?(\/|$)/), 'неверный корень backend');
        ctx.root = args[1];
        ctx.state = ctx.root + '/etc/zapret-manager';
        ctx.base = ctx.root + '/opt/zapret';
        ctx.config = ctx.root + '/etc/config/zapret';
        ctx.assets = ctx.state + '/assets';
    }
    if ((command == 'manager-install' || command == 'manager-uninstall' || command == 'uninstall') && getenv('DESTDIR')) {
        let destination = getenv('DESTDIR');
        check(match(destination, /^\/[A-Za-z0-9_./ -]+$/) && !match(destination, /(^|\/)\.\.?(\/|$)/), 'неверный DESTDIR');
        ctx.root = destination == '/' ? '' : replace(destination, /\/$/, '');
        ctx.state = ctx.root + '/etc/zapret-manager';
        ctx.base = ctx.root + '/opt/zapret';
        ctx.config = ctx.root + '/etc/config/zapret';
        ctx.assets = ctx.state + '/assets';
    }
    if (command == 'uninstall') {
        arity(args, 1, 1);
        check(index(['manager', 'all'], args[0]) != -1, 'ожидается manager или all');
        if (args[0] == 'all') {
            check(!getenv('ZM_TRANSACTION'), 'пакетная операция внутри транзакции запрещена');
            check(!fs.stat(ctx.root + '/tmp/zapret-manager.zapret.lock'), 'занято: выполняется другая операция');
            run(ctx, 'package', ['remove']);
            return backend(ctx, 'transaction', [...(fs.stat(ctx.file) ? ['--config', ctx.file] : []), 'uninstall-finish', 'all']) == 0 ? 0 : 1;
        }
    }
    if (command == 'uninstall-finish') check(getenv('ZM_TRANSACTION'), 'внутренняя команда транзакции');
    if (index(['install', 'update', 'remove', 'install-upstream', 'update-upstream'], command) != -1)
        return package_phase(ctx, command, args);
    // Pure input errors need neither a snapshot nor a worker; validate again under the lock.
    if (command == 'config' && args[0] == 'set') {
        arity(args, 3, 3);
        editable(ctx, args[1], args[2]);
    }
    let readonly = (command == 'backend-operation' &&
        (index(['status', 'doctor', 'config-read', 'config-read-optional', 'hosts-read-stdout', 'settle'], args[0]) != -1 ||
         (args[0] == 'network' && args[3] == 'status'))) || index(['status', 'doctor', 'test', 'recover', 'blockcheck', 'manager-check'], command) != -1 ||
        (command == 'network' && args[0] == 'status') ||
        (command == 'devices' && args[0] == 'list') ||
        (command == 'fake' && args[0] == 'list') ||
        (command == 'source' && index(['list', 'show'], args[0]) != -1) ||
        (command == 'strategy' && index(['list', 'show', 'validate'], args[0]) != -1) ||
        (command == 'config' && index(['show', 'get'], args[0]) != -1) ||
        (command == 'hosts' && args[1] == 'show');
    if (!readonly && !getenv('ZM_TRANSACTION')) {
        // A POSIX supervisor owns the lock, signal handling and rollback for the entire command.
        let rc = backend(ctx, 'transaction', argv);
        return rc == 0 ? 0 : 1;
    }
    dispatch(ctx, command, args);
    return 0;
}
catch (e) {
    warn('zapret-manager: ' + e.message + '\n');
    return 1;
}
};
