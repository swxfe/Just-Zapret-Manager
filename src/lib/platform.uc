import * as fs from 'fs';
import * as uci from 'uci';
import * as ubus from 'ubus';
import { cached } from 'cache';

export function config_cursor(ctx, writeable) {
    // Ignore shared CLI deltas and runtime overrides; workers use their private delta directory.
    let delta = writeable ? getenv('ZM_TRANSACTION') + '/delta' : '/dev/null';
    let handle = uci.cursor(ctx.root + '/etc/config', delta, '', { strict: true, print_errors: false });
    if (handle == null) die('не удалось создать UCI cursor: ' + uci.error());
    return handle;
};

export function config_values(ctx, package, section) {
    return cached(ctx, 'uci:' + package + ':' + section, () => {
        let st = fs.stat(ctx.root + '/etc/config/' + package);
        if (st?.type != 'file' || st.size > ctx.max_file_bytes) die('неверный размер UCI: ' + package);
        let handle = config_cursor(ctx, false);
        if (!handle.load(package)) die('не удалось прочитать UCI ' + package + ': ' + uci.error());
        let values = handle.get_all(package, section);
        if (values == null) die('основная секция конфига не найдена: ' + package);
        return values;
    });
};

export function config_option(ctx, key, optional) {
    if (!match(key, /^[A-Za-z][A-Za-z0-9_]*$/)) die('неверное имя опции');
    let value = config_values(ctx, 'zapret', '@main[0]')[key];
    if (value == null) {
        if (!optional) die('опция UCI не найдена: ' + key);
        return '';
    }
    if (type(value) == 'array') value = join(' ', value);
    if (type(value) != 'string' || length(value) > ctx.max_file_bytes || index(value, '\x00') != -1)
        die('неверное значение UCI: ' + key);
    return value + '\n';
};

export function host_path(ctx, kind) {
    let names = { user: 'zapret-hosts-user.txt', exclude: 'zapret-hosts-user-exclude.txt', google: 'zapret-hosts-google.txt' };
    if (!exists(names, kind)) die('неизвестный список доменов');
    return ctx.base + '/ipset/' + names[kind];
};

export function native_running(ctx) {
    // Off-root fixtures use their own bus, with precisely the same native RPC path.
    let socket = ctx.root == '' ? null : ctx.root + '/tmp/ubus.sock';
    let connection = ubus.connect(socket, 1);
    if (connection == null) return null;
    let reply;
    try { reply = connection.call('service', 'list', { name: 'zapret' }); }
    catch (e) { connection.disconnect(); return null; }
    connection.disconnect();
    return reply;
};

export function executable(name) {
    for (let directory in split(getenv('PATH') || '/usr/sbin:/usr/bin:/sbin:/bin', ':')) {
        let path = (length(directory) ? directory : '.') + '/' + name;
        if (fs.stat(path)?.type == 'file' && fs.access(path, 'x')) return path;
    }
    return null;
};
