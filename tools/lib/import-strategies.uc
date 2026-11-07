import { check, read } from '../../src/lib/common.uc';
import { validate_body, profile_group, parse_catalog } from '../../src/lib/strategies.uc';

function windows_tokens(text) {
    let args = [], word = '', quoted = false;
    for (let i = 0; i < length(text); i++) {
        let c = substr(text, i, 1);
        if (c == '"') { quoted = !quoted; continue; }
        if (c == '^') {
            let next = substr(text, i + 1, 1);
            if (next == '!') { word += '^!'; i++; continue; }
            check(next == '\n' || next == '\r' || next == ' ', 'неподдерживаемое экранирование BAT');
            continue;
        }
        if (!quoted && match(c, /^[[:space:]]$/)) {
            if (length(word)) { push(args, word); word = ''; }
        }
        else word += c;
    }
    check(!quoted, 'незакрытая кавычка BAT');
    if (length(word)) push(args, word);
    return args;
}

export function flowseal_strategy(ctx, text) {
    let command = '', active = false;
    for (let raw in split(replace(text, /\r/g, ''), '\n')) {
        let line = trim(raw);
        if (!active && match(line, /^start[[:space:]].*winws\.exe/i)) {
            active = true;
            line = substr(line, index(lc(line), 'winws.exe') + 9);
            line = substr(line, index(line, '--'));
        }
        if (!active) continue;
        command += line + '\n';
        if (!match(line, /\^$/)) break;
    }
    check(active, 'команда winws в BAT не найдена');
    let blocks = [[]];
    for (let arg in windows_tokens(command)) {
        if (arg == '--new') { push(blocks, []); continue; }
        if (match(arg, /^--wf-/)) continue;
        check(substr(arg, 0, 2) == '--', 'неожиданный токен BAT: ' + arg);
        push(blocks[-1], arg);
    }
    let result = [];
    for (let block in blocks) {
        let joined = join(' ', block);
        let supported = match(joined, /^--filter-udp=19294-19344,50000-50100/) ||
            match(joined, /^--filter-tcp=%GameFilterTCP%/) || match(joined, /^--filter-udp=%GameFilterUDP%/) ||
            match(joined, /^--filter-tcp=2053,2083,2087,2096,8443/) ||
            match(joined, /^--filter-tcp=443 --hostlist=%LISTS%list-google.txt/) ||
            match(joined, /^--filter-tcp=80,443 --hostlist=%LISTS%list-general.txt/);
        if (!supported) continue;
        let converted = [];
        for (let arg in block) {
            if (match(arg, /^--ipset(-exclude)?=/) ||
                match(arg, /^--hostlist=%LISTS%list-general(-user)?\.txt$/) ||
                arg == '--hostlist-exclude=%LISTS%list-exclude-user.txt') continue;
            arg = replace(arg, '%GameFilterTCP%', ctx.sources.tcp_ports);
            arg = replace(arg, '%GameFilterUDP%', ctx.sources.udp_ports);
            arg = replace(arg, '%LISTS%list-google.txt', '/opt/zapret/ipset/zapret-hosts-google.txt');
            arg = replace(arg, '%LISTS%list-exclude.txt', '/opt/zapret/ipset/zapret-hosts-user-exclude.txt');
            arg = replace(arg, '^!', '%BIN%tls_clienthello_www_google_com.bin');
            let m = match(arg, /%BIN%([A-Za-z0-9_.-]+\.bin)/);
            if (m) {
                let original = m[1];
                check(match(original, /^[A-Za-z0-9_.-]+\.bin$/), 'неверное имя fake-файла');
                arg = replace(arg, '%BIN%' + original, '/opt/zapret/fakes/' + original);
            }
            check(!match(arg, /%[A-Za-z_][A-Za-z0-9_]*%/), 'неизвестная переменная BAT: ' + arg);
            push(converted, arg);
        }
        if (length(converted)) push(result, join('\n', converted));
    }
    check(length(result) && length(filter(result, (block) =>
        index(block, '--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt') != -1 ||
        match(block, /^--filter-tcp=80,443(\n|,)/))),
        'нет полной переносимой TCP/YouTube-стратегии; частичные блоки не импортированы');
    return { body: validate_body(join('\n--new\n', result)) };
};


export function flowseal_groups(body) {
    let groups = {};
    for (let block in split(validate_body(body), '--new\n')) {
        let kind = profile_group(block, true);
        check(kind != null, 'неизвестная группа профиля Flowseal');
        if (!groups[kind]) groups[kind] = [];
        push(groups[kind], block);
    }
    let result = {};
    for (let kind, blocks in groups) result[kind] = validate_body(join('--new\n', blocks));
    return result;
};

export function manager_catalog(ctx, source, youtube) {
    // Accept upstream's safe "--option value" spelling, store canonical --option=value.
    let canonical_options = (body) => join('\n', map(split(body, '\n'), (line) => {
        let option = match(trim(line), /^(--[A-Za-z0-9][A-Za-z0-9_-]*)[ \t]+([A-Za-z0-9_.,:\/+=@%{}!~-]+)$/);
        return option ? option[1] + '=' + option[2] : line;
    }));
    let imported_body = (body) => validate_body(canonical_options(body));
    let result = [];
    for (let line in split(source, '\n')) {
        let m = match(line, /^strategy_(v[0-9]+)\(\) \{ printf /);
        if (m) {
            let quoted = split(line, '"'), args = [];
            for (let i = 1; i < length(quoted); i += 2)
                if (substr(quoted[i], 0, 2) == '--') push(args, quoted[i]);
            push(result, { name: m[1], body: imported_body(join('\n', args)) });
        }
        m = match(line, /^(Dv[0-9]+)=\$'([^']*)'/);
        if (m) push(result, { name: m[1], body: imported_body(replace(m[2], /\\n/g, '\n')) });
    }
    check(length(result), 'в исходном менеджере не найдены стратегии v/Dv');
    for (let s in parse_catalog(ctx, canonical_options(youtube))) push(result, s);
    for (let s in parse_catalog(ctx, read(ctx.home + '/data/manager-strategies.txt', ctx.max_file_bytes))) if (match(s.name, /^Gv/)) push(result, s);
    return join('', map(result, (s) => '#' + s.name + '\n' + s.body));
};
