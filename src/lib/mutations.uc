import * as fs from 'fs';
import * as uci from 'uci';
import { cached, invalidate } from 'cache';
import { config_cursor, config_values, host_path, native_running } from 'platform';

function tx_check(ok, message) { if (!ok) die(message); }

function tx_lock(ctx) {
    let path = ctx.root + '/tmp/zapret-manager.zapret.lock';
    tx_check(getenv('ZM_TRANSACTION') == path && fs.stat(path + '/ready')?.type == 'file', 'нет активной транзакции');
    return path;
}

function tx_write(path, text) {
    tx_check(fs.writefile(path, text) == length(text), 'ошибка записи: ' + path);
}

function tx_marker(ctx, name) { tx_write(tx_lock(ctx) + '/' + name, '1\n'); }

function tx_append(path, text) {
    let previous = fs.stat(path)?.size || 0;
    let journal = fs.open(path, 'a');
    tx_check(journal != null, 'не удалось открыть журнал: ' + path);
    let count = journal.write(text);
    journal.close();
    tx_check(count == length(text) && fs.stat(path)?.size == previous + length(text), 'ошибка записи журнала: ' + path);
}

function tx_changed(ctx, path) {
    tx_append(tx_lock(ctx) + '/changed', path + '\n');
    invalidate(ctx);
}

function tx_directory(path) {
    let st = fs.lstat(path);
    if (st != null) { tx_check(st.type == 'directory', 'каталог заменён ссылкой или файлом: ' + path); return; }
    tx_directory(fs.dirname(path));
    tx_check(fs.mkdir(path, 0700), 'не удалось создать каталог: ' + path);
}

function tx_token() {
    let token = trim(fs.readfile('/proc/sys/kernel/random/uuid', 64) || '');
    tx_check(match(token, /^[a-f0-9-]{36}$/), 'не удалось получить случайное имя');
    return token;
}

function tx_allowed(ctx, path) {
    let prefix = ctx.state + '/', base = ctx.base + '/';
    return (substr(path, 0, length(prefix)) == prefix && !match(substr(path, length(prefix)), /(^|\/)\.\.?(\/|$)/)) ||
        path == ctx.config || path == ctx.base + '/config' ||
        path == ctx.root + '/etc/config/firewall' || path == ctx.root + '/etc/crontabs/root' ||
        path == ctx.root + '/usr/bin/jzm' || path == ctx.root + '/usr/bin/jzm.previous' ||
        substr(path, 0, length(base)) == base || substr(path, 0, length(ctx.root + '/tmp/')) == ctx.root + '/tmp/';
}

function tx_same(path, body) {
    let st = fs.lstat(path);
    return st?.type == 'file' && st.size == length(body) && fs.readfile(path, st.size + 1) == body;
}

// Configuration payloads stay in this process. Only safety primitives absent from
// stable fs (statvfs, link, timestamp-preserving snapshot) go to the supervisor.
function tx_put(ctx, path, body, mode, safety, exclusive) {
    tx_lock(ctx);
    tx_check(tx_allowed(ctx, path) && index(path, '\x00') == -1 && !match(path, /[\r\n]|(^|\/)\.\.?(\/|$)/), 'запись вне разрешённых путей');
    if (exclusive) tx_check(fs.lstat(path) == null, 'файл резервной копии уже существует');
    let old = fs.lstat(path), permissions = mode != null ? mode : (old?.type == 'file' ? old.mode & 0777 : 0600);
    if (tx_same(path, body) && (old.mode & 0777) == permissions) return false;
    safety(ctx, 'check-space', [int((length(body) + 1023) / 1024)]);
    tx_directory(fs.dirname(path));
    // Refuse parent-directory links: rename must publish inside the managed tree.
    let parent = fs.dirname(path);
    tx_check(fs.realpath(parent) == parent, 'каталог записи выходит за разрешённый путь: ' + parent);
    let temporary = parent + '/.zm-' + tx_token();
    if (exclusive) tx_append(tx_lock(ctx) + '/backup.links', path + '\n' + temporary + '\n');
    safety(ctx, 'snapshot-path', [path]);
    tx_append(tx_lock(ctx) + '/staged.paths', temporary + '\n');
    let file = fs.open(temporary, 'wx', 0600);
    tx_check(file != null, 'не удалось создать временный файл: ' + temporary);
    try {
        let count = file.write(body);
        file.close(); file = null;
        tx_check(count == length(body) && fs.stat(temporary)?.size == length(body), 'ошибка записи: ' + temporary);
        if (old?.type == 'file') tx_check(fs.chown(temporary, old.uid, old.gid), 'не удалось сохранить владельца: ' + path);
        tx_check(fs.chmod(temporary, permissions), 'не удалось сохранить права: ' + path);
        tx_changed(ctx, path);
        if (exclusive) safety(ctx, 'backup-publish', [temporary, path]);
        else tx_check(fs.rename(temporary, path), 'не удалось атомарно заменить: ' + path);
    }
    catch (e) { if (file != null) file.close(); if (!exclusive) fs.unlink(temporary); die(e.message); }
    return true;
}

function tx_remove(ctx, path, safety) {
    tx_check(tx_allowed(ctx, path), 'удаление вне разрешённых путей');
    if (fs.lstat(path) == null) return false;
    safety(ctx, 'snapshot-path', [path]);
    tx_changed(ctx, path);
    tx_check(fs.unlink(path), 'не удалось удалить: ' + path);
    return true;
}

function tx_service(ctx, action) {
    tx_check(index(['start', 'stop', 'restart', 'enable', 'disable'], action) != -1, 'неверное действие сервиса');
    let init = ctx.root + '/etc/init.d/zapret';
    tx_check(fs.access(init, 'x'), 'не найден init-скрипт: ' + init);
    tx_lock(ctx);
    if (index(['start', 'stop', 'restart'], action) != -1) {
        tx_marker(ctx, 'service.touched');
        tx_changed(ctx, ctx.config);
        tx_changed(ctx, ctx.base + '/config');
    }
    else tx_marker(ctx, 'service.touched');
    let sync = ctx.base + '/sync_config.sh';
    if ((action == 'start' || action == 'restart') && fs.stat(sync))
        tx_check(system(['/bin/sh', sync]) == 0, 'ошибка sync_config.sh');
    // These scripts belong to Zapret/procd; the manager adds no shell dispatcher.
    tx_check(system([init, action]) == 0, 'сервис zapret: ошибка ' + action);
    invalidate(ctx);
}

function tx_config(ctx, args, safety) {
    tx_lock(ctx);
    tx_check(length(args) > 0 && length(args) % 2 == 0, 'нужны пары опция/значение');
    for (let i = 0; i < length(args); i += 2)
        tx_check(match(args[i], /^[A-Za-z][A-Za-z0-9_]*$/), 'неверное имя опции');
    let handle = config_cursor(ctx, true);
    tx_check(handle.load('zapret') && handle.get('zapret', '@main[0]') == 'main', 'основная секция конфига не найдена');
    let changed = false;
    for (let i = 0; i < length(args); i += 2) {
        if (handle.get('zapret', '@main[0]', args[i]) == args[i + 1]) continue;
        tx_check(handle.set('zapret', '@main[0]', args[i], args[i + 1]), 'ошибка UCI set: ' + uci.error());
        changed = true;
    }
    if (!changed) return;
    safety(ctx, 'check-space', [int(((fs.stat(ctx.config)?.size || 0) + length(join('', args)) + 1023) / 1024)]);
    tx_changed(ctx, ctx.config);
    tx_check(handle.commit('zapret'), 'ошибка UCI commit: ' + uci.error());
}

function tx_firewall(ctx, args, safety) {
    if (args[0] == 'status') {
        let state = cached(ctx, 'firewall-status', () => {
            let handle = config_cursor(ctx, false);
            tx_check(handle.load('firewall'), 'firewall OpenWrt не найден');
            let values = handle.get_all('firewall', '@defaults[0]');
            tx_check(values != null, 'не найдена основная секция firewall');
            return { values, blocked: handle.get('firewall', 'jzm_quic', 'name') == 'JZM_Block_QUIC' };
        });
        printf('Программный Flow Offloading: %s\nАппаратный Flow Offloading: %s\nQUIC: %s\n',
            state.values.flow_offloading || '0', state.values.flow_offloading_hw || '0',
            state.blocked ? 'заблокирован JZM' : 'JZM не блокирует');
        return;
    }
    let values = config_values(ctx, 'firewall', '@defaults[0]');
    let handle = config_cursor(ctx, true);
    tx_check(handle.load('firewall'), 'firewall OpenWrt не найден');
    tx_lock(ctx);
    let restart = false, saved = ctx.state + '/offload.previous';
    if (args[0] == 'offload') {
        let original = [values.flow_offloading ?? 'x', values.flow_offloading_hw ?? 'x'];
        let next;
        if (args[1] == 'disable') {
            if (fs.lstat(saved) == null) tx_put(ctx, saved, join('\n', original) + '\n', null, safety);
            next = ['0', '0'];
        }
        else {
            tx_check(args[1] == 'restore', 'неверная настройка совместимости');
            let body = fs.readfile(saved, 17);
            tx_check(body != null && match(body, /^[01x]\n[01x]\n$/), 'сохранённых параметров Flow Offloading нет или они повреждены');
            next = split(trim(body), '\n');
        }
        for (let i = 0; i < 2; i++) {
            let key = i == 0 ? 'flow_offloading' : 'flow_offloading_hw';
            if (original[i] != next[i]) restart = true;
            if (next[i] == 'x') { if (handle.get('firewall', '@defaults[0]', key) != null)
                tx_check(handle.delete('firewall', '@defaults[0]', key), 'ошибка удаления UCI'); }
            else tx_check(handle.set('firewall', '@defaults[0]', key, next[i]), 'ошибка записи UCI');
        }
        if (args[1] == 'restore') tx_remove(ctx, saved, safety);
    }
    else {
        tx_check(args[0] == 'quic' && index(['on', 'off'], args[1]) != -1, 'неверная настройка совместимости');
        let existing = handle.get('firewall', 'jzm_quic', 'name');
        tx_check(existing == null || existing == 'JZM_Block_QUIC', 'имя правила jzm_quic уже занято');
        if (args[1] == 'off') { if (handle.get('firewall', 'jzm_quic') != null)
            tx_check(handle.delete('firewall', 'jzm_quic'), 'ошибка удаления правила QUIC'); }
        else {
            tx_check(handle.set('firewall', 'jzm_quic', 'rule'), 'ошибка создания правила QUIC');
            for (let key, value in { name: 'JZM_Block_QUIC', src: 'lan', dest: 'wan', proto: 'udp', dest_port: '80 443', target: 'REJECT', family: 'any' })
                tx_check(handle.set('firewall', 'jzm_quic', key, value), 'ошибка записи правила QUIC');
        }
    }
    safety(ctx, 'check-space', [int(((fs.stat(ctx.root + '/etc/config/firewall')?.size || 0) + 4095) / 1024)]);
    tx_marker(ctx, 'firewall.touched');
    if (restart) tx_marker(ctx, 'firewall.restart');
    tx_changed(ctx, ctx.root + '/etc/config/firewall');
    tx_check(handle.commit('firewall'), 'ошибка UCI commit firewall');
    tx_check(system([ctx.root + '/etc/init.d/firewall', restart ? 'restart' : 'reload']) == 0, 'ошибка применения firewall');
}

function tx_schedule(ctx, args, safety) {
    let file = ctx.root + '/etc/crontabs/root', tag = '# zapret-manager:zapret';
    let original = fs.stat(file) ? fs.readfile(file, 65537) : '';
    tx_check(original != null && length(original) <= 65536 && index(original, '\x00') == -1, 'неверный crontab');
    let lines = split(original, '\n');
    if (lines[-1] == '') pop(lines);
    lines = filter(lines, (line) => substr(line, -length(tag)) != tag);
    if (args[1] != 'off') {
        tx_check(match(args[1], /^([0-9]|1[0-9]|2[0-3])$/), 'час: 0..23');
        for (let path in [args[0], args[2], args[3]])
            tx_check(type(path) == 'string' && match(path, /^\/[A-Za-z0-9_./-]+$/) && !match(path, /(^|\/)\.\.?(\/|$)/),
                'для расписания нужны абсолютные пути без метасимволов');
        push(lines, '0 ' + args[1] + ' * * * JZM_MODE=command /bin/sh ' + ctx.root + '/usr/bin/jzm --config ' + args[0] +
            ' auto-best ' + args[2] + ' ' + args[3] + ' >' + ctx.root + '/tmp/zapret-manager.log 2>&1 ' + tag);
    }
    let text = length(lines) ? join('\n', lines) + '\n' : '';
    if (text == original) return;
    tx_check(fs.access(ctx.root + '/etc/init.d/cron', 'x'), 'не найден cron');
    tx_put(ctx, file, text, null, safety);
    tx_check(system([ctx.root + '/etc/init.d/cron', 'restart']) == 0, 'cron: ошибка перезапуска');
}

function tx_remove_tree(path, depth) {
    tx_check(depth < 32, 'слишком глубокий каталог удаления');
    let st = fs.lstat(path);
    if (st == null) return;
    if (st.type != 'directory') { tx_check(fs.unlink(path), 'не удалось удалить: ' + path); return; }
    let names = fs.lsdir(path);
    tx_check(names != null && length(names) <= 50000, 'не удалось прочитать каталог удаления: ' + path);
    for (let name in names) tx_remove_tree(path + '/' + name, depth + 1);
    tx_check(fs.rmdir(path), 'не удалось удалить каталог: ' + path);
}

function tx_uninstall(ctx, mode, safety) {
    tx_check(index(['manager', 'all'], mode) != -1, 'ожидается manager или all');
    tx_lock(ctx);
    safety(ctx, 'snapshot-uninstall', [mode]);
    if (fs.stat(ctx.state + '/offload.previous')) tx_firewall(ctx, ['offload', 'restore'], safety);
    if (fs.stat(ctx.root + '/etc/config/firewall')) {
        let handle = config_cursor(ctx, false);
        if (handle.get('firewall', 'jzm_quic', 'name') == 'JZM_Block_QUIC') tx_firewall(ctx, ['quic', 'off'], safety);
    }
    tx_schedule(ctx, [ctx.file, 'off'], safety);
    let hook = ctx.base + '/init.d/openwrt/custom.d/20-jzm-exclude.sh';
    if (mode == 'manager') {
        if (tx_remove(ctx, hook, safety)) {
            let saved = ctx.state + '/legacy-exclusion-hook.sh', legacy = ctx.base + '/init.d/openwrt/custom.d/20-script.sh';
            if (fs.stat(saved)) {
                tx_check(fs.lstat(legacy) == null, 'старый хук уже существует; удаление отменено');
                tx_put(ctx, legacy, fs.readfile(saved), null, safety);
            }
            if (fs.access(ctx.root + '/etc/init.d/zapret', 'x')) {
                let reply = native_running(ctx), running = false;
                tx_check(type(reply) == 'object' && (reply.zapret == null || type(reply.zapret.instances) == 'object'),
                    'не удалось проверить сервис перед удалением');
                if (reply.zapret != null)
                    for (let name, instance in reply.zapret.instances) if (instance.running == true) running = true;
                if (running) tx_service(ctx, 'restart');
            }
        }
    }
    else {
        tx_remove(ctx, ctx.config, safety);
        if (fs.lstat(ctx.base)) { tx_changed(ctx, ctx.base); tx_remove_tree(ctx.base, 0); }
    }
    tx_remove(ctx, ctx.root + '/usr/bin/jzm', safety);
    tx_remove(ctx, ctx.root + '/usr/bin/jzm.previous', safety);
    if (fs.lstat(ctx.state)) { tx_changed(ctx, ctx.state); tx_remove_tree(ctx.state, 0); }
}

export function native_send(ctx, action, args, text, safety) {
    let path;
    switch (action) {
    case 'hosts-write': path = host_path(ctx, args[0]); break;
    case 'state-write':
        tx_check(match(args[0], /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/), 'неверное имя файла');
        path = ctx.state + '/' + args[0]; break;
    case 'source-write':
        tx_check(index(['manager', 'flowseal'], args[0]) != -1, 'неизвестный источник');
        path = ctx.state + '/' + args[0] + '.json'; break;
    case 'device-hook-write': {
        let legacy = ctx.base + '/init.d/openwrt/custom.d/20-script.sh';
        let saved = ctx.state + '/legacy-exclusion-hook.sh';
        if (args[0] == 'migrate') {
            if (fs.lstat(saved) == null) tx_put(ctx, saved, fs.readfile(legacy), null, safety);
            tx_remove(ctx, legacy, safety);
        }
        tx_put(ctx, ctx.base + '/init.d/openwrt/custom.d/20-jzm-exclude.sh', text, 0755, safety);
        return true;
    }
    case 'config-restore': {
        let lock = tx_lock(ctx), stage = lock + '/validate';
        tx_directory(stage);
        tx_write(stage + '/zapret', text);
        let handle = uci.cursor(stage, stage + '/delta', '', { strict: true, print_errors: false });
        let valid = handle != null && handle.load('zapret') && handle.get('zapret', '@main[0]') == 'main';
        fs.unlink(stage + '/zapret'); fs.rmdir(stage);
        tx_check(valid, 'резервная копия содержит неверный UCI или нет основной UCI-секции');
        path = ctx.config; break;
    }
    case 'manager-install': {
        let destination = args[0];
        tx_check(destination == ctx.root, 'путь установки не совпадает с транзакцией');
        // Validation executes the bundle's own version entry; no live files are touched yet.
        let lock = tx_lock(ctx), temporary = lock + '/manager-candidate';
        tx_write(temporary, text);
        safety(ctx, 'manager-validate', [temporary]);
        let target = ctx.root + '/usr/bin/jzm';
        if (fs.stat(target)) tx_put(ctx, target + '.previous', fs.readfile(target), 0755, safety);
        tx_put(ctx, target, text, 0755, safety);
        fs.unlink(temporary);
        return true;
    }
    case 'manager-config-init':
        tx_check(args[0] == ctx.root, 'путь установки не совпадает с транзакцией');
        path = ctx.state + '/manager-config.json';
        if (fs.lstat(path)) return true;
        break;
    case 'resource-bytes': {
        tx_check(match(args[0], /^[A-Za-z0-9_][A-Za-z0-9_.-]*\.bin$/) && length(text) > 0 && length(text) <= ctx.max_file_bytes,
            'неверный bin-ресурс');
        let path = ctx.base + '/files/fake/' + args[0];
        if (fs.lstat(path)) return true;
        tx_append(tx_lock(ctx) + '/created_fakes', args[0] + '\n');
        tx_put(ctx, path, text, null, safety);
        return true;
    }
    case 'backup-write': {
        tx_check(length(text) > 0, 'пустая резервная копия');
        let path = args[0], temporary = ctx.root + '/tmp/', backups = ctx.state + '/backups/';
        tx_check(type(path) == 'string' && match(path, /^[A-Za-z0-9_./ -]+$/) && !match(path, /(^|\/)\.\.?(\/|$)/) &&
            (substr(path, 0, length(temporary)) == temporary || substr(path, 0, length(backups)) == backups),
            'копия разрешена только в backups/ или /tmp/');
        tx_put(ctx, path, text, null, safety, true);
        return true;
    }
    default: return false;
    }
    tx_put(ctx, path, text, null, safety);
    return true;
};

export function native_action(ctx, action, args, safety) {
    switch (action) {
    case 'config-set': tx_config(ctx, args, safety); return true;
    case 'service': tx_service(ctx, args[0]); return true;
    case 'network': tx_firewall(ctx, args, safety); return true;
    case 'strategy-state-clear': tx_remove(ctx, ctx.state + '/state.json', safety); return true;
    case 'settle':
        tx_check(length(args) == 1 && type(+args[0]) == 'int' && +args[0] >= 0 && +args[0] <= 60, 'неверный интервал ожидания');
        sleep(+args[0] * 1000); return true;
    case 'resource-write': {
        tx_check(match(args[1], /^[A-Za-z0-9_][A-Za-z0-9_.-]*\.bin$/), 'неверное имя bin-ресурса');
        let path = ctx.base + '/files/fake/' + args[1];
        if (fs.lstat(path) != null) return true;
        let st = fs.stat(args[0]);
        tx_check(st?.type == 'file' && st.size > 0 && st.size <= ctx.max_file_bytes, 'неверный размер bin-ресурса');
        let body = fs.readfile(args[0], ctx.max_file_bytes + 1);
        tx_check(body != null && length(body) == st.size, 'ошибка чтения bin-ресурса');
        tx_append(tx_lock(ctx) + '/created_fakes', args[1] + '\n');
        tx_put(ctx, path, body, null, safety);
        return true;
    }
    case 'manager-install': {
        let text = fs.readfile(args[0], ctx.max_file_bytes + 1);
        tx_check(text != null && length(text) <= ctx.max_file_bytes, 'не удалось прочитать обновление');
        return native_send(ctx, action, [args[1]], text, safety);
    }
    case 'schedule': tx_schedule(ctx, args, safety); return true;
    case 'uninstall-cleanup': tx_uninstall(ctx, args[0], safety); return true;
    case 'manager-uninstall':
        tx_remove(ctx, ctx.root + '/usr/bin/jzm', safety);
        tx_remove(ctx, ctx.root + '/usr/bin/jzm.previous', safety);
        return true;
    }
    return false;
};
