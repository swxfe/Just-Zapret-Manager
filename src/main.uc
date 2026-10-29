import { check } from 'common';
import { settings } from 'settings';
import { menu } from 'menu';
import { command_main } from 'commands';

try {
    if (getenv('JZM_MODE') == 'command') exit(command_main(ARGV));
    check(!length(ARGV), 'Запустите менеджер без аргументов: jzm');
    menu(settings(getenv('ZM_HOME'), getenv('JZM_CONFIG')), command_main);
}
catch (e) {
    warn('jzm: ' + e.message + '\n');
    exit(1);
}
