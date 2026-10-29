import { check } from 'common';

export function validate_list_snapshot(text, limit, max_bytes) {
    // Backups preserve upstream's IP/CIDR, suffixes, Unicode and comments verbatim.
    // This is data copied to a fixed list path, never shell source or CLI arguments.
    check(type(text) == 'string' && length(text) <= max_bytes, 'слишком большой список в резервной копии');
    check(index(text, '\x00') == -1 && !match(text, /[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]/),
        'управляющие байты в списке резервной копии');
    // Search bounded byte windows in native code instead of interpreting every byte.
    // This preserves the byte limit for UTF-8 and never allocates a list of lines.
    let count = 0, size = length(text), nonblank = /[^ \t\r]/;
    for (let offset = 0; offset < size;) {
        let window = substr(text, offset, 1025), end = index(window, '\n');
        check(end != -1 || length(window) <= 1024, 'слишком длинная строка списка резервной копии');
        let line = end == -1 ? window : substr(window, 0, end);
        if (match(line, nonblank)) count++;
        check(count <= limit, 'превышен лимит строк списка резервной копии');
        offset += end == -1 ? length(window) : end + 1;
    }
    return true;
};

export function domains(text, limit) {
    let seen = {}, result = [], label_pattern = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/;
    for (let raw in split(text, '\n')) {
        let name = lc(trim(split(raw, '#')[0]));
        if (!length(name)) continue;
        check(length(name) <= 253 && index(name, '.') != -1, 'неверный домен: ' + name);
        for (let label in split(name, '.'))
            check(length(label) <= 63 && match(label, label_pattern), 'неверный домен: ' + name);
        if (!exists(seen, name)) {
            seen[name] = true;
            push(result, name);
        }
        check(length(result) <= limit, 'превышен лимит доменов');
    }
    return sort(result);
};

export function urls(text, limit) {
    let result = [];
    for (let raw in split(text, '\n')) {
        let url = trim(raw);
        if (!length(url) || substr(url, 0, 1) == '#') continue;
        check(length(url) <= 2048, 'URL длиннее 2048 байт');
        check(match(url, /^https?:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?(\/[^[:space:]]*)?$/), 'неверный URL: ' + url);
        push(result, url);
        check(length(result) <= limit, 'превышен лимит URL');
    }
    check(length(result) > 0, 'список URL пуст');
    return result;
};
