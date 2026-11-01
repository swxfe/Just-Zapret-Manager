import * as fs from 'fs';
import { resource } from 'resources';
import { config_option, host_path, native_running, executable } from 'platform';
import { native_send, native_action } from 'mutations';
import { cached, invalidate } from 'cache';
import { http_request } from 'http';

export function check(condition, message) {
    if (!condition) die(message);
};

export function tempdir() {
    // mkdir is the exclusive allocation primitive available on every supported ucode.
    for (let attempt = 0; attempt < 8; attempt++) {
        let token = trim(fs.readfile('/proc/sys/kernel/random/uuid', 64) || '');
        check(match(token, /^[a-f0-9-]{36}$/), 'не удалось получить случайное имя');
        let path = '/tmp/zm-io-' + token;
        if (fs.mkdir(path, 0700)) return path;
        check(fs.lstat(path) != null, 'невозможно создать временный каталог: ' + fs.error());
    }
    die('невозможно создать уникальный временный каталог');
};

export function read(path, limit) {
    let st = fs.stat(path);
    check(st != null && st.type == 'file', 'не найден обычный файл: ' + path);
    check(st.size <= limit, 'слишком большой файл: ' + path);
    let value = fs.readfile(path, limit + 1);
    check(value != null && length(value) <= limit, 'ошибка чтения: ' + path);
    check(index(value, '\x00') == -1, 'NUL в текстовом файле: ' + path);
    return value;
};

function backend_command(ctx, action, args) {
    let cmd = getenv('JZM_BACKEND') ? ['/bin/sh', '-c', getenv('JZM_BACKEND'), 'jzm-backend', action, ctx.root, ctx.profile] :
        ['/bin/sh', ctx.home + '/src/shell/backend.sh', action, ctx.root, ctx.profile];
    for (let arg in (args || [])) push(cmd, '' + arg);
    return cmd;
}

function safety_operation(ctx, action, args) {
    let rc = system(backend_command(ctx, action, args));
    check(rc == 0, sprintf('%s: код завершения %d', action, rc));
}

export function backend(ctx, action, args) {
    args = args || [];
    if (native_action(ctx, action, args, safety_operation)) return 0;
    if (action == 'probe') {
        try {
            let reply = http_request(ctx, args[2], ctx.max_file_bytes, true, true);
            return reply.status >= 200 && reply.status < 300 ? 0 : 22;
        }
        catch (e) { warn(e.message + '\n'); return 28; }
    }
    if (action == 'status') {
        if (!fs.stat(ctx.root + '/etc/init.d/zapret')) print('zapret: not installed\n');
        else {
            let reply = native_running(ctx), running = false;
            check(type(reply) == 'object', 'не удалось проверить состояние сервиса');
            if (reply.zapret != null) {
                check(type(reply.zapret.instances) == 'object', 'неверный ответ procd');
                for (let name, instance in reply.zapret.instances) if (instance.running == true) running = true;
            }
            print(running ? 'zapret: running\n' : 'zapret: stopped\n');
        }
        return 0;
    }
    if (action == 'doctor') {
        let errors = 0;
        for (let name in ['ucode', 'uci', 'curl', 'mktemp']) {
            let found = executable(name) != null;
            printf('%s %s\n', found ? 'OK' : 'MISSING', name);
            if (!found) errors++;
        }
        if (!executable('opkg') && !executable('apk')) { print('MISSING opkg/apk\n'); errors++; }
        for (let path in [ctx.config, ctx.root + '/etc/init.d/zapret'])
            if (!fs.stat(path)) { printf('MISSING %s\n', path); errors++; }
        return errors ? 1 : 0;
    }
    if (action == 'transaction') {
        let rc = system(['env', 'JZM_REPORT_CHANGE=1', ...backend_command(ctx, action, args)]);
        if (rc == 10) { invalidate(ctx); return 0; }
        // An incomplete rollback is not the state represented by the old cache.
        if (rc != 0 && fs.stat(ctx.root + '/tmp/zapret-manager.zapret.lock/ready')) invalidate(ctx);
        return rc;
    }
    return system(backend_command(ctx, action, args));
};

export function run(ctx, action, args) {
    let rc = backend(ctx, action, args);
    check(rc == 0, sprintf('%s: код завершения %d', action, rc));
};

export function output(ctx, action, args) {
    if (action == 'config-get' || action == 'config-get-optional')
        return config_option(ctx, args[0], action == 'config-get-optional');
    if (action == 'hosts-read') {
        let path = host_path(ctx, args[0]);
        return cached(ctx, 'hosts:' + args[0], () => fs.stat(path) ? read(path, ctx.max_file_bytes) : '');
    }
    if (action == 'architecture') {
        let body = read(ctx.root + '/etc/openwrt_release', 65536);
        let arch = match(body, /(^|\n)DISTRIB_ARCH='([A-Za-z0-9_-]+)'(\n|$)/);
        check(arch != null, 'не удалось определить архитектуру OpenWrt');
        return arch[2] + '\n';
    }
    if (action == 'download' || action == 'github-download') {
        let reply;
        try { reply = http_request(ctx, args[3], +args[2], false); }
        catch (e) { die(action + ': код завершения 28: ' + e.message); }
        if (action == 'github-download')
            return reply.status + '\n' + (reply.headers['x-ratelimit-remaining'] || '') + '\n' + reply.body;
        check(reply.status >= 200 && reply.status < 300, 'ошибка HTTP ' + reply.status);
        return reply.body;
    }
    die('неизвестная операция чтения: ' + action);
};

export function write(path, text) {
    check(fs.writefile(path, text) == length(text), 'ошибка записи: ' + path);
};

export function send(ctx, action, args, text) {
    check(native_send(ctx, action, args || [], text, safety_operation), 'неизвестная операция записи: ' + action);
};

export function invoke(ctx, args) {
    return backend(ctx, 'transaction', [...(fs.stat(ctx.file) ? ['--config', ctx.file] : []), ...args]);
};

export function target_text(ctx, file) {
    return file == '@default' ? resource(ctx.home, 'urls.txt') : read(file, ctx.max_file_bytes);
};
