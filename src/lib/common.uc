import * as fs from 'fs';
import { resource } from 'resources';

export function check(condition, message) {
    if (!condition) die(message);
};

export function tempdir() {
    // The fs.mkdtemp API is absent from ucode shipped with OpenWrt 24.10.
    // This fixed command has no caller-provided arguments to interpolate.
    let proc = fs.popen('mktemp -d /tmp/zm-io-XXXXXX', 'r');
    check(proc != null, 'невозможно запустить mktemp');
    let path = trim(proc.read('all') || '');
    let rc = proc.close();
    check(rc == 0 && match(path, /^\/tmp\/zm-io-[A-Za-z0-9]+$/),
          'невозможно создать временный каталог');
    return path;
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

export function backend(ctx, action, args) {
    return system(backend_command(ctx, action, args));
};

export function run(ctx, action, args) {
    let rc = backend(ctx, action, args);
    check(rc == 0, sprintf('%s: код завершения %d', action, rc));
};

export function output(ctx, action, args) {
    let stream = { 'config-get': 'config-read', 'config-get-optional': 'config-read-optional',
                   'hosts-read': 'hosts-read-stdout' }[action];
    if (stream != null) {
        let cmd = backend_command(ctx, stream, args);
        let quoted = map(cmd, (arg) => "'" + replace(arg, /'/g, "'\\''") + "'");
        let proc = fs.popen(join(' ', quoted), 'r');
        check(proc != null, 'не удалось запустить ' + action);
        let value = '', oversized = false;
        // Drain an oversized result before close, keeping memory bounded and avoiding a full pipe deadlock.
        for (let chunk = proc.read(4096); chunk != null && length(chunk); chunk = proc.read(4096)) {
            if (!oversized) value += chunk;
            if (length(value) > ctx.max_file_bytes) oversized = true;
        }
        let rc = proc.close();
        check(rc == 0, sprintf('%s: код завершения %d', action, rc));
        check(!oversized, 'слишком большой результат ' + action);
        check(index(value, '\x00') == -1, 'NUL в текстовом результате: ' + action);
        return value;
    }
    // Capture through a private directory; arguments never pass through a shell parser.
    let dir = tempdir();
    let value;
    try {
        run(ctx, action, [dir + '/result', ...(args || [])]);
        value = read(dir + '/result', ctx.max_file_bytes);
    }
    catch (e) {
        fs.unlink(dir + '/result');
        fs.rmdir(dir);
        die(e.message);
    }
    fs.unlink(dir + '/result');
    fs.rmdir(dir);
    return value;
};

export function write(path, text) {
    check(fs.writefile(path, text) == length(text), 'ошибка записи: ' + path);
};

export function send(ctx, action, args, text) {
    let dir = tempdir();
    try {
        write(dir + '/input', text);
        run(ctx, action, [dir + '/input', ...(args || [])]);
    }
    catch (e) {
        fs.unlink(dir + '/input');
        fs.rmdir(dir);
        die(e.message);
    }
    fs.unlink(dir + '/input');
    fs.rmdir(dir);
};

export function invoke(ctx, args) {
    let cmd = getenv('JZM_BOOTSTRAP') ?
        ['/bin/sh', '-c', 'JZM_MODE=command exec ucode -S -e "$JZM_BOOTSTRAP" -- "$@"', 'jzm-command'] :
        ['/bin/sh', '-c', 'JZM_MODE=command exec /bin/sh "$@"', 'jzm-command', ctx.home + '/src/launcher.sh'];
    return system([...cmd, ...(fs.stat(ctx.file) ? ['--config', ctx.file] : []), ...args]);
};

export function target_text(ctx, file) {
    return file == '@default' ? resource(ctx.home, 'urls.txt') : read(file, ctx.max_file_bytes);
};
