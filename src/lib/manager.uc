import * as fs from 'fs';
import { cached } from 'cache';
import { check, read, send, invoke, output } from 'common';
import { embedded_header, embedded_footer, VERSION } from 'resources';
import { default_settings } from 'settings';
import { install_assets } from 'assets';

export function newer_version(candidate, current) {
    check(type(candidate) == 'string' && match(candidate, /^[0-9]+\.[0-9]+\.[0-9]+$/), 'неверная версия менеджера');
    let a = split(candidate, '.'), b = split(current, '.');
    for (let i = 0; i < 3; i++) {
        if (+a[i] != +b[i]) return +a[i] > +b[i];
    }
    return false;
};

function shell_value(name, body) {
    let marker = '__JZM_' + name + '__';
    return name + "=$(cat <<'" + marker + "'\n" + trim(body) + '\n' + marker + '\n)\nexport ' + name + '\n\n';
}

export function render_bundle(ctx) {
    if (embedded_header() == null) {
        check(system(['/bin/sh', ctx.home + '/tools/bundle.sh']) == 0, 'не удалось собрать jzm');
        return read(ctx.home + '/dist/just-zapret-manager.sh', ctx.max_file_bytes);
    }
    let body = embedded_header() + shell_value('JZM_BACKEND', getenv('JZM_BACKEND'));
    let count = +getenv('JZM_PARTS');
    for (let i = 1; i <= count; i++) body += shell_value('JZM_UCODE_' + i, getenv('JZM_UCODE_' + i));
    return body + 'JZM_PARTS=' + count + '\nexport JZM_PARTS\n' + embedded_footer();
};

export function install_manager(ctx, archive) {
    if (!getenv('ZM_TRANSACTION')) { check(invoke(ctx, ['manager-install', ...(archive ? [archive] : [])]) == 0, 'не удалось установить менеджер'); return; }
    let destination = getenv('DESTDIR') || ctx.root;
    check(destination == '' || (match(destination, /^\/[A-Za-z0-9_./ -]+$/) && !match(destination, /(^|\/)\.\.?(\/|$)/)), 'неверный DESTDIR');
    if (archive != null) install_assets(ctx, archive);
    send(ctx, 'manager-install', [destination], render_bundle(ctx));
    let path = ctx.assets + '/resources/manager.json';
    let config = fs.stat(path) ? json(read(path, 65536)) : default_settings();
    send(ctx, 'manager-config-init', [destination], sprintf('%J\n', config));
    // Early builds saved an empty update source; migrate only that known default.
    let saved = destination + '/etc/zapret-manager/manager-config.json';
    let previous = null;
    try { previous = json(read(saved, 65536)); } catch (e) { /* Preserve custom files. */ }
    if (previous?.updater?.repo == '' && index(['dist/Zapret-Manager.sh', 'dist/just-zapret-manager.sh'], previous.updater.path) != -1) {
        previous.updater = config.updater;
        send(ctx, 'state-write', ['manager-config.json'], sprintf('%J\n', previous));
    }
    printf('Установлено: %s/usr/bin/jzm\nКонфигурация: %s/etc/zapret-manager/manager-config.json\n', destination, destination);
};

function update_origin(ctx) {
    return ctx.updater.repo + '/' + ctx.updater.branch + '/' + ctx.updater.path;
}

function update_remote(ctx, url) {
    check(match(url, /^https:\/\/[A-Za-z0-9_.\/-]+$/), 'неверный URL обновления');
    let body = output(ctx, 'download', [ctx.connect_timeout, ctx.request_timeout, ctx.max_file_bytes, url]);
    check(length(body), 'не удалось получить обновление');
    return body;
}

function compute_update_status(ctx) {
    if (!length(ctx.updater.repo)) return { label: 'источник не настроен', available: false };
    let path = ctx.state + '/update.json';
    try {
        let data = json(read(path, 65536));
        check(data.origin == update_origin(ctx) && match(data.revision, /^[a-f0-9]{40}$/), 'неверный кэш обновления');
        data.available = newer_version(data.version, VERSION);
        data.label = data.version + (data.available ? ' — доступно обновление [u]' : '');
        return data;
    }
    catch (e) { return { label: 'ещё не проверена', available: false }; }
};

export function update_status(ctx) {
    return cached(ctx, 'update-status', () => compute_update_status(ctx));
};

export function check_update(ctx) {
    check(length(ctx.updater.repo), 'источник обновлений не настроен в updater.repo');
    let base = 'https://api.github.com/repos/' + ctx.updater.repo;
    let revision = json(update_remote(ctx, base + '/commits/' + ctx.updater.branch)).sha;
    check(type(revision) == 'string' && match(revision, /^[a-f0-9]{40}$/), 'неверная ревизия обновления');
    let body = update_remote(ctx, 'https://raw.githubusercontent.com/' + ctx.updater.repo + '/' + revision + '/' + ctx.updater.path);
    let version = match(body, /(^|\n)# JZM_VERSION=([0-9]+\.[0-9]+\.[0-9]+)(\n|$)/);
    check(version && match(body, /(^|\n)# JZM_FORMAT=2(\n|$)/), 'источник не содержит совместимую сборку JZM');
    newer_version(version[2], VERSION);
    let data = { origin: update_origin(ctx), revision, version: version[2], checked: time() };
    if (getenv('ZM_TRANSACTION')) cache_update(ctx, data);
    else check(invoke(ctx, ['manager-cache', sprintf('%J', data)]) == 0, 'не удалось сохранить проверку обновления');
    return update_status(ctx);
};

export function cache_update(ctx, data) {
    check(getenv('ZM_TRANSACTION') && type(data) == 'object' && data.origin == update_origin(ctx) &&
        type(data.revision) == 'string' && match(data.revision, /^[a-f0-9]{40}$/) &&
        type(data.checked) == 'int' && data.checked > 0, 'неверный кэш обновления');
    newer_version(data.version, VERSION);
    if (getenv('JZM_BACKGROUND_UPDATE') == '1' && fs.stat(ctx.root + '/usr/bin/jzm') == null) return;
    send(ctx, 'state-write', ['update.json'], sprintf('%J\n', data));
};

export function apply_update(ctx) {
    if (!getenv('ZM_TRANSACTION')) { check(invoke(ctx, ['manager-update']) == 0, 'не удалось обновить менеджер'); return; }
    let info = update_status(ctx);
    check(info.available, 'новой версии нет; сначала проверьте обновления');
    let body = update_remote(ctx, 'https://raw.githubusercontent.com/' + ctx.updater.repo + '/' + info.revision + '/' + ctx.updater.path);
    check(index(body, '\n# JZM_VERSION=' + info.version + '\n') != -1 && match(body, /(^|\n)# JZM_FORMAT=2(\n|$)/), 'версия загруженного файла не совпала');
    send(ctx, 'manager-install', [ctx.root], body);
    printf('Менеджер обновлён до %s. Предыдущая сборка: /usr/bin/jzm.previous\nЗапустите jzm заново.\n', info.version);
};
