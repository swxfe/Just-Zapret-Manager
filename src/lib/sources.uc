import { resource } from 'resources';
import { package_versions, release_plan } from 'status';
import * as fs from 'fs';
import { check, read, output, run, send, tempdir } from 'common';
import { catalog, parse_catalog, validate_body, strategy_key } from 'strategies';

export function github_response(response) {
    let first = index(response, '\n'), tail = substr(response, first + 1), next = index(tail, '\n');
    check(first == 3 && next != -1, 'неверный ответ HTTP от GitHub API');
    let second = first + 1 + next;
    let status = substr(response, 0, first), remaining = substr(response, first + 1, second - first - 1);
    let body = substr(response, second + 1);
    check(match(status, /^[1-5][0-9]{2}$/), 'неверный статус HTTP от GitHub API');
    check(!(status == '429' || (status == '403' && (remaining == '0' ||
        match(lc(body), /rate limit exceeded|secondary rate limit/)))),
        'Превышен лимит запросов GitHub API (60/час на ваш IP). Попробуйте позже или используйте встроенные стратегии');
    check(substr(status, 0, 1) == '2', 'GitHub API: ошибка HTTP ' + status);
    return body;
};

function remote(ctx, url) {
    if (substr(url, 0, 23) == 'https://api.github.com/')
        return github_response(output(ctx, 'github-download', [ctx.connect_timeout,
            ctx.request_timeout, ctx.max_file_bytes - 64, url]));
    return output(ctx, 'download', [ctx.connect_timeout, ctx.request_timeout, ctx.max_file_bytes, url]);
}

function revision(ctx, repo) {
    let reply = json(remote(ctx, 'https://api.github.com/repos/' + repo + '/commits/' + ctx.sources.branch));
    check(type(reply.sha) == 'string' && match(reply.sha, /^[a-f0-9]{40}$/), 'источник не вернул commit SHA');
    return reply.sha;
}

function raw_url(repo, rev, path) {
    check(match(rev, /^[a-f0-9]{40}$/) && match(path, /^[A-Za-z0-9_ .()\/-]+$/) &&
          !match(path, /(^|\/)\.\.?(\/|$)/), 'неверный путь источника');
    return 'https://raw.githubusercontent.com/' + repo + '/' + rev + '/' + replace(path, / /g, '%20');
}

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
    for (let s in catalog(ctx)) if (match(s.name, /^Gv/)) push(result, s);
    return join('', map(result, (s) => '#' + s.name + '\n' + s.body));
};

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
    let result = [], assets = {};
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
                let original = m[1], local = ctx.sources.fake_aliases[original] || original;
                check(match(local, /^[A-Za-z0-9_.-]+\.bin$/), 'неверное имя fake-файла');
                let remote = match(original, /^ACTIVE_/) ? local : original;
                assets[local] = 'bin/' + remote;
                arg = replace(arg, '%BIN%' + original, '/opt/zapret/files/fake/' + local);
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
    return { body: validate_body(join('\n--new\n', result)), assets };
};

export function source_file(ctx, kind) {
    check(kind == 'manager' || kind == 'flowseal', 'неизвестный источник');
    return ctx.state + '/' + kind + '.json';
};

export function source_data(ctx, kind, wanted) {
    let file = source_file(ctx, kind);
    if (!fs.stat(file)) {
        check(kind == 'manager', 'сначала обновите каталог Flowseal в меню');
        let text = resource(ctx.home, 'strategies.txt');
        return { catalog: text, strategies: parse_catalog(ctx, text, wanted), assets: {}, revision: 'встроенный' };
    }
    let value = json(read(file, ctx.max_file_bytes));
    check(value.format == 1 && value.source == kind && type(value.revision) == 'string' &&
          length(value.revision) == 40 && match(value.revision, /^[a-f0-9]+$/) &&
          type(value.assets) == 'object', 'повреждён каталог источника');
    check(type(value.catalog) == 'string', 'повреждён текст каталога источника');
    value.strategies = parse_catalog(ctx, value.catalog, wanted);
    return value;
};

export function refresh_source(ctx, kind) {
    source_file(ctx, kind);
    let repo = ctx.sources[kind + '_repo'], rev = revision(ctx, repo), assets = {}, text = '', skipped = [];
    if (kind == 'manager') {
        text = manager_catalog(ctx, remote(ctx, raw_url(repo, rev, 'Zapret-Manager.sh')),
            remote(ctx, raw_url(repo, rev, 'files/StrYoutube')));
    }
    else {
        let tree = json(remote(ctx, 'https://api.github.com/repos/' + repo + '/git/trees/' + rev + '?recursive=1'));
        check(type(tree.tree) == 'array' && !tree.truncated, 'неполное дерево репозитория Flowseal');
        for (let file in tree.tree) {
            if (file.type != 'blob' || !match(file.path, /^general[A-Za-z0-9_ .()-]*\.bat$/i)) continue;
            try {
                let converted = flowseal_strategy(ctx, remote(ctx, raw_url(repo, rev, file.path)));
                let name = strategy_key(replace(replace(file.path, /\.bat$/i, ''), /[^A-Za-z0-9_.-]+/g, '_'));
                text += '#' + name + '\n' + converted.body;
                for (let local, path in converted.assets) assets[local] = path;
            }
            catch (e) { push(skipped, file.path + ': ' + e.message); }
        }
    }
    let list = parse_catalog(ctx, text);
    let value = { format: 1, source: kind, revision: rev, catalog: text, assets, skipped };
    let body = sprintf('%J\n', value);
    check(length(body) <= ctx.max_file_bytes, 'каталог источника слишком большой');
    send(ctx, 'source-write', [kind], body);
    printf('Обновлено стратегий: %d\nРевизия: %s\n', length(list), rev);
    for (let line in skipped) printf('Пропущено: %s\n', line);
};

export function prepare_assets(ctx, kind, body, prepared) {
    let data = prepared || source_data(ctx, kind, []), repo = ctx.sources[kind + '_repo'], pinned = null;
    for (let line in split(body, '\n')) {
        let m = match(line, /^--[^=]+=\/opt\/zapret\/files\/fake\/([A-Za-z0-9_.-]+\.bin)$/);
        if (!m || fs.stat(ctx.base + '/files/fake/' + m[1])) continue;
        let local = m[1], path = data.assets[local];
        // Manager strategies use the same supplemental fake files as the original manager.
        if (kind == 'manager') {
            repo = ctx.sources.flowseal_repo;
            let aliases = { '4pda.bin': 'tls_clienthello_4pda_to.bin',
                'tls_clienthello_www_onetrust_com.bin': 'tls_clienthello_max_ru.bin' };
            path = 'bin/' + (aliases[local] || local);
        }
        check(path != null, 'источник не содержит fake-файл: ' + local);
        if (kind == 'manager' && pinned == null) pinned = revision(ctx, repo);
        let rev = kind == 'manager' ? pinned : data.revision;
        let dir = tempdir();
        try {
            run(ctx, 'check-space', [int((ctx.max_file_bytes + 1023) / 1024)]);
            run(ctx, 'download', [dir + '/blob', ctx.connect_timeout, ctx.request_timeout,
                ctx.max_file_bytes, raw_url(repo, rev, path)]);
            run(ctx, 'resource-write', [dir + '/blob', local]);
        }
        catch (e) { fs.unlink(dir + '/blob'); fs.rmdir(dir); die(e.message); }
        fs.unlink(dir + '/blob'); fs.rmdir(dir);
    }
};

export function release_install(ctx) {
    let release = json(remote(ctx, 'https://api.github.com/repos/' + ctx.sources.installer_repo + '/releases/latest'));
    check(type(release.tag_name) == 'string' && match(release.tag_name, /^v[0-9.]+$/) &&
          type(release.assets) == 'array', 'неверные данные релиза Zapret');
    let versions = package_versions(ctx);
    check(versions.zapret || !fs.stat(ctx.root + '/etc/init.d/zapret'),
        'Zapret найден без записи версии пакета; автоматическая переустановка отменена');
    let plan = release_plan(versions, release.tag_name);
    if (plan == 'none') { print('Zapret и LuCI актуальны. Новых версий нет, переустановка не требуется.\n'); return 'none'; }
    let arch = trim(output(ctx, 'architecture'));
    check(match(arch, /^[A-Za-z0-9_-]+$/), 'не удалось определить архитектуру OpenWrt');
    let name = 'zapret_' + release.tag_name + '_' + arch + '.zip';
    let selected = filter(release.assets, (a) => a.name == name);
    check(length(selected) == 1, 'нет сборки Zapret для архитектуры ' + arch);
    let url = 'https://github.com/' + ctx.sources.installer_repo + '/releases/download/' + release.tag_name + '/' + name;
    check(selected[0].browser_download_url == url && type(selected[0].size) == 'int' &&
        selected[0].size > 0 && selected[0].size <= 16777216, 'неверный файл релиза');
    let digest = selected[0].digest || '';
    check(digest == '' || match(digest, /^sha256:[a-f0-9]{64}$/), 'неверный SHA256 релиза');
    printf('Релиз Zapret: %s\n%s\n', release.tag_name, plan == 'luci' ?
        'Устанавливается недостающий LuCI-пакет для этой версии Zapret.' : 'Устанавливаются Zapret и luci-app-zapret.');
    run(ctx, 'release-install', [url, substr(digest, 7), ctx.connect_timeout, ctx.request_timeout, plan, int((selected[0].size + 1023) / 1024)]);
    return plan;
};
