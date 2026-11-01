# just-zapret-manager

**JZM** — менеджер Zapret для OpenWrt с меню в терминале.

- Установка и обновление Zapret и LuCI, управление сервисом.
- Стратегии Flowseal и Zapret Manager, профили для YouTube, Discord и игр.
- Списки доменов, исключения устройств и резервные копии.
- Проверка сайтов, сравнение стратегий и blockcheck.

## Установка

Подключитесь к роутеру по SSH от `root` и выполните:

```sh
wget -O /tmp/jzm-install.sh https://raw.githubusercontent.com/swxfe/just-zapret-manager/main/tools/bootstrap.sh && sh /tmp/jzm-install.sh
```

Установщик добавит зависимости, установит команду `jzm` и откроет меню.
Последующие запуски — `jzm`.

Изменения конфигурации выполняются со снимком и откатом при ошибке.

Подробности установки, настройки, удаления и разработки — в [install.md](install.md).

Лицензия — [GPL-3.0](LICENSE).
