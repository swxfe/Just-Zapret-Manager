import * as fs from 'fs';
import { VERSION } from 'resources';

let root = getenv('ZM_HOME');
function content(path) {
    let value = fs.readfile(root + '/' + path);
    if (value == null) die('bundle: не найден ' + path);
    return replace(value, /\r\n/g, '\n');
}
function module_body(path) {
    let body = content(path);
    body = join('\n', map(filter(split(body, '\n'), (line) => !match(line, /^import /)),
        (line) => replace(line, /^export /, '')));
    return '\n// ---- ' + path + ' ----\n' + body;
}
function shell_body(name) {
    let body = content('src/shell/' + name + '.sh');
    body = join('\n', filter(split(body, '\n'), (line) => !match(line, /^(#!|# shellcheck source=|\. "\$\(dirname)/)));
    return body;
}
function heredoc(name, body) {
    let marker = '__JZM_' + name + '__';
    if (index('\n' + body, '\n' + marker + '\n') != -1) die('bundle: конфликт разделителя');
    return name + "=$(cat <<'" + marker + "'\n" + trim(body) + '\n' + marker + '\n)\nexport ' + name + '\n\n';
}

let header = replace(content('tools/header.sh'), /@VERSION@/g, VERSION);
let footer = content('tools/footer.sh');
let backend = shell_body('common') + '\n';
for (let name in ['transaction', 'packages', 'network', 'uninstall'])
    backend += '\njzm_' + name + '() {\n' + shell_body(name) + '\n}\n';
let dispatch = shell_body('backend');
for (let name in ['transaction', 'packages', 'network', 'uninstall'])
    dispatch = replace(dispatch,
        'exec /bin/sh "$(dirname "$0")/' + name + '.sh" "$action" "$root" "$profile" "$@"',
        'jzm_' + name + ' "$@"');
backend += '\n# ---- system operation dispatcher ----\n' + dispatch;

let strategies = content('data/strategies.txt');
if (match(strategies, /[`$\\]/)) die('bundle: небезопасный символ в шаблоне стратегий');
let program = "import * as fs from 'fs';\n";
program += 'const EMBEDDED_STRATEGIES = `\n' + strategies + '`;\n';
let config = content('data/manager.json');
if (type(json(config)) != 'object') die('bundle: manager.json должен содержать объект');
program += 'const EMBEDDED_CONFIG = ' + trim(config) + ';\n';
program += 'const EMBEDDED_DATA = {};\n';
for (let file in ['sources.json', 'network.json', 'google.txt', 'exclude.txt', 'urls.txt']) {
    let value = content('data/' + file);
    if (match(value, /[`$\\]/)) die('bundle: небезопасный символ в ресурсе ' + file);
    program += 'EMBEDDED_DATA[' + sprintf('%J', file) + '] = `' + value + '`;\n';
}
program += "EMBEDDED_DATA['strategies.txt'] = EMBEDDED_STRATEGIES;\n";
program += 'const EMBEDDED_HEADER = ' + sprintf('%J', header) + ';\n';
program += 'const EMBEDDED_FOOTER = ' + sprintf('%J', footer) + ';\n';
for (let file in ['resources', 'common', 'settings', 'strategies', 'domains', 'devices', 'applied', 'status', 'sources', 'manager', 'menu']) {
    let body = module_body('src/lib/' + file + '.uc');
    if (file == 'resources') {
        for (let kind in ['data', 'config', 'header', 'footer'])
            body = replace(body, 'function embedded_' + kind + '() { return null; }',
                'function embedded_' + kind + '() { return EMBEDDED_' + uc(kind) + '; }');
    }
    program += body;
}
program += module_body('src/lib/commands.uc') + module_body('src/main.uc');

// Split only between lines so UTF-8 and the concatenated source remain intact.
let parts = [], part = '';
for (let line in split(program, '\n')) {
    if (length(part) + length(line) > 24000 && length(part)) { push(parts, part); part = ''; }
    part += line + '\n';
}
if (length(part)) push(parts, part);
let result = header + heredoc('JZM_BACKEND', backend);
for (let i = 0; i < length(parts); i++) result += heredoc('JZM_UCODE_' + (i + 1), parts[i]);
result += 'JZM_PARTS=' + length(parts) + '\nexport JZM_PARTS\n' + footer;
let target = root + '/dist/just-zapret-manager.sh';
fs.mkdir(root + '/dist');
if (fs.writefile(target, result) != length(result)) die('bundle: ошибка записи');
fs.chmod(target, 0755);
printf('%s (%d bytes, readable source)\n', target, length(result));
