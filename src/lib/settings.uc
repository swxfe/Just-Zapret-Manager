import * as fs from 'fs';
import { resource, embedded_config } from 'resources';
import { check, read } from 'common';

export function settings(home, file) {
    file = file || (fs.stat('/etc/zapret-manager/manager-config.json') ? '/etc/zapret-manager/manager-config.json' : null);
    let c = file ? json(read(file, 65536)) : (embedded_config() || json(read(home + '/data/manager.json', 65536)));
    c = json(sprintf('%J', c));
    check(type(c) == 'object', 'manager.json: ожидается объект');
    let allowed = ['root', 'updater', 'connect_timeout', 'request_timeout',
        'settle_seconds', 'max_file_bytes', 'max_domains', 'max_strategies',
        'max_urls', 'hostlist_urls', 'sources'];
    for (let key in keys(c))
        check(index(allowed, key) != -1, 'неизвестная настройка: ' + key);
    c.profile = 'zapret';
    check(type(c.root) == 'string' && match(c.root, /^\/([A-Za-z0-9_. -]+\/)*[A-Za-z0-9_. -]*$/) &&
          !match(c.root, /(^|\/)\.\.?(\/|$)/), 'root: нужен абсолютный путь без . и ..');
    c.root = c.root == '/' ? '' : replace(c.root, /\/$/, '');
    for (let key in ['connect_timeout', 'request_timeout', 'settle_seconds',
                     'max_file_bytes', 'max_domains', 'max_strategies', 'max_urls']) {
        check(type(c[key]) == 'int' && c[key] >= (key == 'settle_seconds' ? 0 : 1) &&
              c[key] <= (key == 'max_file_bytes' ? 8388608 : 50000), 'некорректная настройка: ' + key);
    }
    check(c.connect_timeout <= c.request_timeout && c.request_timeout <= 300 &&
          c.settle_seconds <= 60 && c.max_strategies <= 1024 && c.max_urls <= 256,
          'таймауты или лимиты превышены');
    check(type(c.hostlist_urls) == 'object', 'hostlist_urls: ожидается объект');
    for (let key, url in c.hostlist_urls) {
        check(index(['user', 'exclude', 'google'], key) != -1, 'неизвестный список: ' + key);
        check(type(url) == 'string' && match(url, /^https:\/\/[^[:space:]]+$/), 'URL списка должен быть HTTPS');
    }
    c.home = home;
    c.file = file || c.root + '/etc/zapret-manager/manager-config.json';
    c.config = c.root + '/etc/config/' + c.profile;
    c.base = c.root + '/opt/' + c.profile;
    c.state = c.root + '/etc/zapret-manager';
    if (c.sources == null) c.sources = json(resource(home, 'sources.json'));
    check(type(c.sources) == 'object', 'неверные настройки источников');
    for (let key in ['manager_repo', 'flowseal_repo', 'installer_repo'])
        check(type(c.sources[key]) == 'string' && match(c.sources[key], /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/), 'неверный источник: ' + key);
    check(match(c.sources.branch, /^[A-Za-z0-9_.-]+$/), 'неверная ветка источника');
    check(type(c.sources.fake_aliases) == 'object', 'неверная таблица fake-файлов');
    if (c.updater == null) c.updater = { repo: '', branch: 'main', path: 'dist/just-zapret-manager.sh' };
    check(type(c.updater) == 'object' && type(c.updater.repo) == 'string' &&
        (c.updater.repo == '' || match(c.updater.repo, /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/)), 'неверный репозиторий обновлений');
    check(match(c.updater.branch, /^[A-Za-z0-9_.-]+$/) &&
        match(c.updater.path, /^[A-Za-z0-9_.\/-]+$/) && !match(c.updater.path, /(^|\/)\.\.?(\/|$)/), 'неверный путь обновлений');
    return c;
};
