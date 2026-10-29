import * as fs from 'fs';
import { check, invoke } from 'common';
import { VERSION } from 'resources';
import { update_status, check_update, apply_update, start_update_check } from 'manager';
import { strategy_key, strategy_group, strategy_title, strategy_order } from 'strategies';
import { source_data } from 'sources';
import { device_list, excluded } from 'devices';
import { zapret_status, strategy_state, group_state } from 'status';

let ended = false;

function paint(code, text) {
    let enabled = getenv('JZM_COLOR') == 'always' || (fs.stdout.isatty() &&
        getenv('NO_COLOR') == null && getenv('TERM') != 'dumb');
    return enabled ? '\x1b[' + code + 'm' + text + '\x1b[0m' : text;
}

function menu_line(key, text) { printf('  %s %s\n', paint('36;1', key + '.'), text); }

function prompt(label, fallback) {
    fs.stdout.write(paint('33;1', label) + (fallback != null ? ' [' + fallback + ']' : '') + ': ');
    fs.stdout.flush();
    let line = '';
    while (true) {
        let c = fs.stdin.read(1);
        if (c == null || !length(c)) { ended = true; return null; }
        if (c == '\n') break;
        if (c != '\r') line += c;
        check(length(line) <= 4096, 'слишком длинный ввод');
    }
    line = trim(line);
    return !length(line) && fallback != null ? '' + fallback : line;
}

function pause() { if (!ended) prompt('Нажмите Enter', null); }

function screen(title) {
    if (fs.stdout.isatty()) print('\x1b[2J\x1b[H');
    print('\n────────────────────────────────────────\n');
    printf('  %s\n', paint('36;1', 'JZM · ' + title));
    print('────────────────────────────────────────\n');
}

function choice(title, labels) {
    screen(title);
    for (let i = 0; i < length(labels); i++) menu_line(i + 1, labels[i]);
    menu_line('0', 'Назад'); print('\n');
    let value = prompt('Выберите пункт', null);
    if (value == null || value == '' || value == '0') return 0;
    check(match(value, /^[0-9]+$/) && +value >= 1 && +value <= length(labels), 'нет такого пункта');
    return +value;
}

let menu_executor = null;

function command(ctx, args) {
    let rc = menu_executor ? menu_executor([...(fs.stat(ctx.file) ? ['--config', ctx.file] : []), ...args]) : invoke(ctx, args);
    check(rc == 0, 'действие не выполнено; причина указана выше');
}

function perform(fn) {
    try { fn(); }
    catch (e) { printf('\n%s\n', paint('31;1', 'Ошибка: ' + e.message)); }
    pause();
}

function confirm(text) {
    while (!ended) {
        let answer = prompt(text + '? [y/N]', null);
        if (answer == null || answer == '' || lc(answer) == 'n') return false;
        if (lc(answer) == 'y') return true;
        print('Введите y или n. Enter — отменить.\n');
    }
    return false;
}

function local_file(label, fallback) {
    let value = prompt(label, fallback);
    check(value != null && length(value), 'путь не указан');
    return value;
}

function current_strategy(state) {
    let text = state.summary;
    printf('Текущая стратегия: %s\n\n', paint('35;1', length(state.sections) > 1 ? '[' + text + ']' : text));
}

function choose_strategy(ctx, kind, group) {
    let page = 0, list = null, revision = '', problem = '';
    while (!ended) {
        if (list == null) {
            try {
                let data = source_data(ctx, kind);
                list = data.strategies; revision = data.revision;
                if (group != null) list = filter(list, (s) => strategy_group(s.name) == group);
                sort(list, strategy_order);
                problem = length(list) ? '' : 'В каталоге нет стратегий этой группы.';
            }
            catch (e) { list = []; problem = e.message; }
        }
        let state = strategy_state(ctx);
        screen(kind == 'flowseal' ? 'Пресеты Flowseal' : 'Выбор · ' +
            { base: 'Базовый трафик', youtube: 'YouTube', discord: 'Discord', games: 'Игры' }[group]);
        if (kind == 'flowseal') current_strategy(state);
        else printf('Сейчас: %s\n\n', paint('35;1', group_state(state.sections, group)));
        let first = page * 12;
        if (length(problem)) printf('%s\n\n', paint('33', problem));
        else {
            for (let i = first; i < length(list) && i < first + 12; i++) {
                let active = length(filter(state.sections, (s) => s.name == strategy_key(list[i].name) && !s.changed)) > 0;
                menu_line(i + 1, paint(active ? '32;1' : '0', strategy_title(list[i].name)) + (active ? '  ← выбрана' : ''));
            }
            printf('\n%s\n', paint('2', 'Каталог: ' + (revision == 'встроенный' ? revision : substr(revision, 0, 8))));
        }
        if (length(list) > 12) printf('  n. Далее   p. Назад по списку   (%d/%d)\n', page + 1, int((length(list) + 11) / 12));
        menu_line('u', 'Обновить каталог');
        menu_line('d', kind == 'flowseal' ? 'Отключить Flowseal, оставить другие стратегии' : 'Отключить эту группу');
        menu_line('0', 'Отмена'); print('\n');
        let value = prompt('Выбор', null);
        if (value == null || value == '' || value == '0') return null;
        value = lc(value);
        if (value == 'd') return { disable: true };
        if (value == 'u') {
            perform(() => command(ctx, ['source', 'refresh', kind]));
            list = null; page = 0; continue;
        }
        if (value == 'n') { if (first + 12 < length(list)) page++; continue; }
        if (value == 'p') { if (page) page--; continue; }
        if (!match(value, /^[0-9]+$/) || +value <= first || +value > length(list) || +value > first + 12) {
            print('Нет такого пункта на этой странице.\n'); pause(); continue;
        }
        return list[+value - 1];
    }
    return null;
}

function edit_group(ctx, group) {
    let selected = choose_strategy(ctx, 'manager', group);
    if (!selected) return;
    let question = selected.disable ? 'Отключить группу, сохранив остальные стратегии' :
        'Применить ' + selected.name + ', сохранив остальные стратегии';
    if (!confirm(question)) return;
    perform(() => {
        command(ctx, selected.disable ? ['source', 'remove', 'manager', group] : ['source', 'group', 'manager', group, selected.name]);
        print('\n' + paint('32;1', 'Сохранено.') + '\n');
    });
}

function compose_menu(ctx) {
    let groups = ['base', 'youtube', 'discord', 'games'];
    let labels = ['Базовый трафик:', 'YouTube:       ', 'Discord:       ', 'Игры:          '];
    while (!ended) {
        let state = strategy_state(ctx), available = [];
        try { available = source_data(ctx, 'manager').strategies; } catch (e) { /* Picker offers catalog repair. */ }
        screen('Собрать стратегию'); current_strategy(state);
        for (let i = 0; i < length(groups); i++) {
            let names = filter(available, (s) => strategy_group(s.name) == groups[i]);
            sort(names, strategy_order);
            let hint = !length(names) ? 'нет в каталоге' : names[0].name + (length(names) > 1 ? '–' + names[-1].name : '');
            let value = group_state(state.sections, groups[i]);
            menu_line(i + 1, labels[i] + '  ' + paint(value == '[отключено]' ? '2' : '35;1', value) + '  ' + paint('2', '(' + hint + ')'));
        }
        print('\nВыберите группу: добавить, заменить или отключить.\n');
        print(paint('2', 'Изменения применяются сразу; остальные группы сохраняются.') + '\n');
        menu_line('0', 'Назад'); print('\n');
        let value = prompt('Выбор', null);
        if (value == null || value == '' || value == '0') return;
        if (!match(value, /^[1-4]$/)) { print('Нет такого пункта.\n'); pause(); continue; }
        edit_group(ctx, groups[+value - 1]);
    }
}

function test_menu(ctx) {
    while (!ended) {
        let c = choice('Тестирование и автоподбор', ['Проверить текущую стратегию', 'Сравнить стратегии Zapret Manager',
            'Сравнить стратегии Flowseal', 'Подобрать и применить лучшую', 'Настроить подбор по расписанию', 'Отключить расписание']);
        if (!c) return;
        perform(() => {
            if (c == 6) { command(ctx, ['schedule', 'off']); return; }
            let file = local_file('Файл с URL для тестов', '@default');
            if (c == 1) { command(ctx, ['test', file]); return; }
            let kind = c == 3 ? 'flowseal' : 'manager';
            if (c == 4 || c == 5) {
                let selected = choice('Источник стратегий', ['Zapret Manager', 'Flowseal']);
                if (!selected) return;
                kind = selected == 1 ? 'manager' : 'flowseal';
            }
            if (c == 5) {
                check(fs.stat(ctx.root + '/usr/bin/jzm') != null, 'сначала установите JZM через установщик');
                let hour = local_file('Час ежедневного запуска, 0–23', '4');
                command(ctx, ['targets', file]);
                command(ctx, ['source', 'export', kind, kind + '.txt']);
                command(ctx, ['schedule', hour, ctx.state + '/urls.txt', ctx.state + '/' + kind + '.txt']);
                return;
            }
            command(ctx, ['source', c == 4 ? 'auto-best' : 'benchmark', kind, file]);
        });
    }
}

function strategy_menu(ctx) {
    while (!ended) {
        screen('Zapret: Стратегии'); current_strategy(strategy_state(ctx));
        menu_line('1', 'Стратегии Flowseal');
        menu_line('2', 'Собрать: основная + YouTube + Discord + игры');
        menu_line('3', 'Тестирование и автоподбор');
        print('\n'); menu_line('f', 'Загрузить свою стратегию из файла');
        menu_line('0', 'Назад'); print('\n');
        let value = prompt('Выбор', null);
        if (value == null || value == '' || value == '0') return;
        if (value == '2') { compose_menu(ctx); continue; }
        if (value == '3') { test_menu(ctx); continue; }
        if (lc(value) == 'f') {
            perform(() => {
                let file = local_file('Файл стратегии', '/root/custom.txt');
                if (confirm('Заменить текущие стратегии содержимым файла')) command(ctx, ['strategy', 'import', file]);
            });
            continue;
        }
        if (value != '1') { print('Нет такого пункта.\n'); pause(); continue; }
        let selected = choose_strategy(ctx, 'flowseal', null);
        if (!selected) continue;
        if (confirm(selected.disable ? 'Отключить Flowseal, сохранив остальные стратегии' :
            'Заменить текущую композицию пресетом ' + strategy_title(selected.name))) {
            perform(() => {
                command(ctx, selected.disable ? ['source', 'remove', 'flowseal'] : ['source', 'apply', 'flowseal', selected.name]);
                print('\n' + paint('32;1', 'Сохранено.') + '\n');
            });
        }
    }
}

function install_menu(ctx) {
    while (!ended) {
        let state = zapret_status(ctx);
        let c = choice('Zapret · ' + (state.installed ? state.version : 'не установлен'),
            state.installed ? ['Обновить Zapret', 'Удалить Zapret', 'Удалить только JZM', 'Удалить всё: JZM + Zapret + LuCI'] :
                ['Установить Zapret', 'Удалить только JZM', 'Удалить всё: JZM + Zapret + LuCI']);
        if (!c) return;
        perform(() => {
            let manager_only = c == (state.installed ? 3 : 2);
            let everything = c == (state.installed ? 4 : 3);
            if (manager_only || everything) {
                print(manager_only ? 'Zapret, LuCI и текущие стратегии останутся. Расписание, правила и исключения JZM будут удалены.\n' :
                    'Будут удалены Zapret, LuCI, JZM, стратегии, списки, fake-файлы и резервные копии.\n');
                if (confirm(manager_only ? 'Удалить JZM и его данные' : 'Полностью удалить JZM и Zapret')) {
                    command(ctx, ['uninstall', manager_only ? 'manager' : 'all']);
                    print(manager_only ? 'JZM удалён. Zapret сохранён.\n' : 'JZM и Zapret удалены.\n');
                    ended = true;
                }
                return;
            }
            if (state.installed && c == 2) {
                if (confirm('Удалить Zapret и его LuCI-пакет')) command(ctx, ['remove']);
                return;
            }
            let source = choice(state.installed ? 'Источник обновления' : 'Источник установки',
                ['Сборка remittor: Zapret + LuCI', 'Настроенные feeds OpenWrt', 'Локальные пакеты']);
            if (!source) return;
            let args = [];
            if (source == 3) {
                push(args, local_file('Пакет Zapret (.ipk/.apk)', null));
                push(args, local_file('Пакет luci-app-zapret (.ipk/.apk)', null));
            }
            if (!confirm(state.installed ? 'Проверить и установить доступные обновления Zapret и LuCI' : 'Установить Zapret и LuCI')) return;
            command(ctx, [source == 1 ? (state.installed ? 'update-upstream' : 'install-upstream') :
                (state.installed ? 'update' : 'install'), ...args]);
        });
    }
}

function service_menu(ctx) {
    while (!ended) {
        let c = choice('Управление ' + ctx.profile, ['Запустить', 'Остановить', 'Перезапустить', 'Включить автозапуск', 'Выключить автозапуск']);
        if (!c) return;
        perform(() => command(ctx, ['service', ['start', 'stop', 'restart', 'enable', 'disable'][c - 1]]));
    }
}

function hosts_menu(ctx) {
    while (!ended) {
        let kinds = ['user', 'exclude', 'google'];
        let c = choice('Домены Zapret', ['Пользовательские домены', 'Исключения', 'YouTube / Google']);
        if (!c) return;
        let kind = kinds[c - 1];
        while (!ended) {
            let action = choice('Список: ' + kind, ['Показать', 'Добавить домены', 'Удалить домены', 'Заменить из файла', 'Обновить из источника']);
            if (!action) break;
            perform(() => {
                if (action == 1) command(ctx, ['hosts', kind, 'show']);
                if (action == 2 || action == 3) {
                    let text = local_file('Домены через пробел', null);
                    command(ctx, ['hosts', kind, action == 2 ? 'add' : 'remove', ...split(text, /[[:space:]]+/)]);
                }
                if (action == 4) command(ctx, ['hosts', kind, 'replace', local_file('Файл со списком доменов', null)]);
                if (action == 5) command(ctx, ['hosts', kind, 'refresh']);
            });
        }
    }
}

function config_menu(ctx) {
    while (!ended) {
        let c = choice('Настройки Zapret', ['Показать конфигурацию', 'IPv6', 'Режим фильтрации',
            'Порты TCP', 'Порты UDP', 'Пользовательские скрипты Zapret', 'Отладочный вывод', 'Исключить устройства из Zapret',
            'Совместимость: Flow Offloading', 'Блокировка QUIC (UDP 80/443)']);
        if (!c) return;
        perform(() => {
            if (c == 1) { command(ctx, ['config', 'show']); return; }
            if (c == 9 || c == 10) {
                command(ctx, ['network', 'status']);
                let action = choice(c == 9 ? 'Flow Offloading' : 'QUIC', c == 9 ?
                    ['Отключить ускорение для совместимости с Zapret', 'Вернуть прежние настройки ускорения'] :
                    ['Блокировать QUIC, использовать TCP', 'Снять блокировку QUIC, созданную JZM']);
                if (action) command(ctx, ['network', c == 9 ? 'offload' : 'quic',
                    c == 9 ? (action == 1 ? 'disable' : 'restore') : (action == 1 ? 'on' : 'off')]);
                return;
            }
            if (c == 8) {
                let devices = device_list(ctx), current = excluded(ctx);
                print('Устройства из DHCP; исключённые проходят без обработки Zapret.\n');
                for (let i = 0; i < length(devices); i++) printf('%d) %s %s %s\n', i + 1,
                    index(current, devices[i].ip) == -1 ? '[Zapret]' : '[Исключён]', devices[i].ip, devices[i].name);
                print('a) Ввести IP вручную   c) Очистить исключения   0) Назад\n');
                let selected = prompt('Устройство', null);
                if (selected == null || selected == '' || selected == '0') return;
                if (selected == 'c') { command(ctx, ['devices', 'clear']); return; }
                let ip;
                if (selected == 'a') ip = local_file('IPv4 устройства', null);
                else {
                    check(match(selected, /^[0-9]+$/) && +selected >= 1 && +selected <= length(devices), 'нет такого устройства');
                    ip = devices[+selected - 1].ip;
                }
                command(ctx, ['devices', 'toggle', ip]);
                return;
            }
            let key, value;
            if (c == 2 || c == 6 || c == 7) {
                let enabled = prompt('1 — включить, 0 — выключить', null);
                check(enabled == '0' || enabled == '1', 'введите 0 или 1');
                key = c == 2 ? 'DISABLE_IPV6' : (c == 6 ? 'DISABLE_CUSTOM' : 'DEBUG');
                value = c != 7 ? (enabled == '1' ? '0' : '1') : enabled;
            }
            if (c == 3) {
                let mode = choice('Режим фильтрации', ['Все соединения', 'По списку доменов', 'Автоматический список', 'По IP-наборам']);
                if (!mode) return;
                key = 'MODE_FILTER'; value = ['none', 'hostlist', 'autohostlist', 'ipset'][mode - 1];
            }
            if (c == 4 || c == 5) {
                key = 'NFQWS_PORTS_' + (c == 4 ? 'TCP' : 'UDP');
                value = local_file('Порты через запятую; диапазоны через дефис', null);
            }
            command(ctx, ['config', 'set', key, value]);
        });
    }
}

function backup_menu(ctx) {
    while (!ended) {
        let c = choice('Резервные копии Zapret', ['Сохранить настройки', 'Восстановить настройки']);
        if (!c) return;
        perform(() => {
            let file = local_file('Файл резервной копии', ctx.state + '/backups/zapret-backup.json');
            if (c == 1 || confirm('Восстановить настройки из ' + file))
                command(ctx, ['backup', c == 1 ? 'save' : 'restore', file]);
        });
    }
}

export function menu(initial, executor) {
    menu_executor = executor;
    let ctx = initial, update_started = false;
    while (!ended) {
        screen('just-zapret-manager ' + VERSION);
        printf('Менеджер: %s\nПоследняя версия менеджера: %s\n', paint('35;1', VERSION), update_status(ctx).label);
        if (!update_started) { start_update_check(ctx); update_started = true; }
        let state = zapret_status(ctx);
        printf('\nZapret: %s\n', state.installed ? paint('32;1', 'установлен · ' + state.version) : paint('31;1', 'не установлен'));
        printf('Сервис: %s\n', paint(state.running ? '32;1' : '33;1', state.running == null ? 'не удалось проверить' : (state.running ? 'запущен' : 'остановлен')));
        printf('%s: %s\n\n', state.running == false ? 'Выбранные стратегии (не запущены)' : 'Стратегии', paint('35', state.strategy));
        let labels = ['Установка / обновление / удаление', 'Запуск и автозапуск', 'Стратегии',
            'Тесты и автоподбор', 'Домены и исключения', 'Настройки Zapret', 'Резервные копии', 'Диагностика и восстановление'];
        for (let i = 0; i < length(labels); i++) menu_line(i + 1, labels[i]);
        menu_line('u', 'Проверить обновления менеджера');
        menu_line('0', 'Выход'); print('\n');
        let value = prompt('Выберите пункт', null);
        if (value == null || value == '' || value == '0') break;
        try {
            switch (lc(value)) {
            case '1': install_menu(ctx); break;
            case '2': service_menu(ctx); break;
            case '3': strategy_menu(ctx); break;
            case '4': test_menu(ctx); break;
            case '5': hosts_menu(ctx); break;
            case '6': config_menu(ctx); break;
            case '7': backup_menu(ctx); break;
            case '8': {
                let c = choice('Диагностика', ['Проверить зависимости и установку', 'Восстановить после аварийного завершения', 'Штатный blockcheck Zapret']);
                if (c) perform(() => command(ctx, [c == 1 ? 'doctor' : (c == 2 ? 'recover' : 'blockcheck')]));
                break;
            }
            case 'u':
                perform(() => {
                    let info = check_update(ctx);
                    printf('Текущая: %s. Последняя: %s\n', VERSION, info.version);
                    if (info.available && confirm('Установить обновление менеджера')) { apply_update(ctx); ended = true; }
                });
                break;
            default: print('Нет такого пункта.\n'); pause();
            }
        }
        catch (e) { printf('\nОшибка: %s\n', e.message); pause(); }
    }
    print('\nДо встречи. Запуск менеджера: jzm\n');
};
