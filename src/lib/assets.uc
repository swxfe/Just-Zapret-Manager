import * as fs from 'fs';
import { sha256 } from 'digest';
import { cached } from 'cache';
import { check, read, run, send } from 'common';
import { VERSION } from 'resources';
import { parse_catalog } from 'strategies';
import { settings } from 'settings';
import { validate_list_snapshot, urls } from 'domains';

export function fake_filename(name) {
    check(type(name) == 'string' && length(name) <= 160 && match(name, /^[A-Za-z0-9_][A-Za-z0-9_.-]*\.bin$/), 'неверное имя фейка');
    return name;
};

export function installed_assets(ctx) {
    return cached(ctx, 'installed-assets', () => {
        let data = json(read(ctx.assets + '/manifest.json', 1048576));
        check(data.format == 1 && type(data.fakes) == 'array', 'повреждён манифест ассетов');
        return data;
    });
};

export function asset_destination(ctx, entry) {
    check(type(entry) == 'object' && type(entry.size) == 'int' && entry.size >= 0 && entry.size <= ctx.max_file_bytes &&
        type(entry.sha256) == 'string' && match(entry.sha256, /^[a-f0-9]{64}$/), 'неверная запись ассета');
    let name = entry.name, expected, destination;
    if (entry.target == 'resource') {
        check(index(['manager.json', 'network.json', 'google.txt', 'exclude.txt', 'user.txt', 'urls.txt', 'strategies.txt'], name) != -1,
            'неизвестный ресурс');
        expected = 'resources/' + name; destination = ctx.assets + '/' + expected;
    }
    else if (entry.target == 'catalog') {
        check(name == 'flowseal.json' || name == 'manager.json', 'неверный каталог стратегий');
        expected = 'catalogs/' + name; destination = ctx.assets + '/' + expected;
    }
    else {
        fake_filename(name);
        check(entry.size > 0, 'пустой fake-ассет');
        check(entry.target == 'fake' && entry.source == 'flowseal', 'неверный тип или источник ассета');
        expected = 'fakes/' + name;
        destination = ctx.base + '/fakes/' + name;
    }
    check(entry.path == expected, 'путь ассета не совпадает с манифестом');
    return destination;
};

function asset_output(archive, member, destination, bytes) {
    let blocks = int((bytes + 511) / 512) + 1;
    check(system(['/bin/sh', '-eu', '-c', 'ulimit -f "$4"; exec tar -xOzf "$1" "$2" > "$3"',
        'jzm-assets', archive, member, destination, '' + blocks]) == 0, 'не удалось прочитать архив ассетов: ' + member);
}

function asset_snapshot(source, destination) {
    let input = fs.open(source, 'r'), output = fs.open(destination, 'wx', 0600), total = 0;
    check(input != null && output != null, 'не удалось подготовить архив');
    try {
        for (let chunk = input.read(65536); chunk != null && length(chunk); chunk = input.read(65536)) {
            total += length(chunk);
            check(total <= 8388608 && output.write(chunk) == length(chunk), 'архив слишком большой или повреждён');
        }
        input.close(); output.close();
    }
    catch (e) { input.close(); output.close(); die(e.message); }
}

function asset_unpack(archive, stage, sizes) {
    let listing = stage + '/members';
    check(system(['/bin/sh', '-eu', '-c', 'ulimit -f 2048; exec tar -tvzf "$1" > "$2"',
        'jzm-assets', archive, listing]) == 0, 'не удалось проверить содержимое архива');
    let names = {}, lines = split(read(listing, 1048576), '\n');
    for (let line in lines) {
        if (!length(line)) continue;
        let fields = split(trim(line), /[[:space:]]+/);
        // Both BusyBox and GNU tar list USTAR regular files as mode owner size date time path.
        check(length(fields) == 6 && match(fields[0], /^-[rwxStTs-]{9}$/) && match(fields[2], /^[0-9]+$/),
            'ссылки и специальные файлы в архиве запрещены');
        let name = fields[5];
        check(exists(sizes, name) && !exists(names, name) && +fields[2] == sizes[name], 'посторонний или повторный файл в архиве: ' + name);
        names[name] = true;
    }
    check(length(names) == length(sizes), 'архив не содержит все файлы манифеста');
    let unpacked = stage + '/unpacked';
    check(fs.mkdir(unpacked, 0700), 'не удалось создать каталог распаковки');
    // The private archive is immutable here; every name, type and expanded size was checked.
    check(system(['tar', '-xzf', archive, '-C', unpacked]) == 0, 'ошибка распаковки ассетов');
    return unpacked;
}

export function install_assets(ctx, archive) {
    let lock = getenv('ZM_TRANSACTION');
    check(lock == ctx.root + '/tmp/zapret-manager.zapret.lock' && fs.stat(lock + '/ready'), 'нет транзакции установки ассетов');
    let st = fs.lstat(archive);
    check(st?.type == 'file' && st.size > 0 && st.size <= 8388608, 'неверный архив ассетов');
    let stage = lock + '/assets-stage';
    check(fs.mkdir(stage, 0700), 'не удалось создать staging ассетов');
    asset_snapshot(archive, stage + '/archive.tar.gz');
    archive = stage + '/archive.tar.gz';
    asset_output(archive, 'manifest.json', stage + '/manifest.json', 1048576);
    let manifest = json(read(stage + '/manifest.json', 1048576));
    check(manifest.format == 1 && manifest.version == VERSION && type(manifest.files) == 'array' &&
        length(manifest.files) > 0 && length(manifest.files) <= 2048 && type(manifest.fakes) == 'array', 'несовместимый архив ассетов');
    let seen = {}, targets = {}, prepared = [], total = 0;
    let sizes = { 'manifest.json': fs.stat(stage + '/manifest.json').size };
    for (let entry in manifest.files) {
        let destination = asset_destination(ctx, entry);
        check(!exists(seen, entry.path) && !exists(targets, destination), 'повторный ассет в архиве');
        seen[entry.path] = true; targets[destination] = entry; sizes[entry.path] = entry.size;
        total += entry.size;
        check(total <= 16777216, 'ассеты превышают лимит распаковки 16 MiB');
        push(prepared, { entry, destination });
    }
    for (let name in ['manager.json', 'network.json', 'google.txt', 'exclude.txt', 'user.txt', 'urls.txt', 'strategies.txt'])
        check(seen['resources/' + name], 'архив не содержит обязательный ресурс: ' + name);
    for (let kind in ['flowseal', 'manager']) check(seen['catalogs/' + kind + '.json'], 'архив не содержит каталог: ' + kind);
    let fake_ids = {};
    for (let fake in manifest.fakes) {
        check(type(fake) == 'object' && type(fake.path) == 'string', 'неверный fake в манифесте');
        let entry = targets[ctx.root + fake.path];
        check(entry?.target == 'fake' && entry.source == fake.source && entry.name == fake.name, 'фейк отсутствует в архиве');
        let id = fake.source + '/' + fake.name;
        check(!exists(fake_ids, id), 'повторный фейк в манифесте'); fake_ids[id] = true;
    }
    run(ctx, 'check-space', [int((total + 1023) / 1024)]);
    let unpacked = asset_unpack(archive, stage, sizes);
    // Validate all bytes before publishing the first managed file.
    for (let item in prepared) {
        item.file = unpacked + '/' + item.entry.path;
        let body = fs.readfile(item.file, ctx.max_file_bytes + 1);
        check(body != null && length(body) == item.entry.size && sha256(body) == item.entry.sha256,
            'контрольная сумма ассета не совпала: ' + item.entry.path);
        let entry = item.entry;
        if (entry.target == 'catalog') {
            let doc = json(body);
            check(doc.format == 1 && doc.source + '.json' == entry.name && type(doc.revision) == 'string' &&
                match(doc.revision, /^[a-f0-9]{40}$/) && type(doc.catalog) == 'string', 'неверный каталог ассетов');
            parse_catalog(ctx, doc.catalog);
        }
        if (entry.target == 'resource') {
            if (entry.name == 'manager.json') settings(ctx.home, item.file);
            else if (entry.name == 'network.json') {
                let cfg = json(body);
                for (let key in ['family', 'table', 'chain'])
                    check(type(cfg[key]) == 'string' && match(cfg[key], /^[A-Za-z_][A-Za-z0-9_]*$/), 'неверная конфигурация nft в ассетах');
                check(type(cfg.mark) == 'string' && match(cfg.mark, /^0x[a-fA-F0-9]{1,8}$/), 'неверная метка nft в ассетах');
            }
            else if (entry.name == 'strategies.txt') parse_catalog(ctx, body);
            else if (entry.name == 'urls.txt') { check(index(body, '\x00') == -1, 'NUL в URL ассетах'); urls(body, ctx.max_urls); }
            else validate_list_snapshot(body, ctx.max_domains, ctx.max_file_bytes);
        }
    }
    for (let item in prepared) {
        run(ctx, 'asset-file', [item.file, item.destination]);
    }
    send(ctx, 'state-assets-manifest', [], sprintf('%J\n', manifest));
    printf('Ассеты %s установлены: %d файлов.\n', manifest.version, length(prepared));
};
