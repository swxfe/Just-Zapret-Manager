# just-zapret-manager

**JZM 0.1** — менеджер Zapret для OpenWrt с простым меню в терминале.
Установка ядра и LuCI, стратегии, списки доменов и резервные копии — в одном месте.

## Установка

Подключитесь к роутеру по SSH от `root` и выполните:

```sh
wget -O /tmp/jzm-install.sh https://raw.githubusercontent.com/swxfe/just-zapret-manager/main/tools/bootstrap.sh && sh /tmp/jzm-install.sh
```

Установщик добавит необходимые зависимости, установит команду `jzm` и откроет меню.
Дальше достаточно запускать:

```sh
jzm
```

Подробности, ручная установка и удаление — в [install.md](install.md).

## Что умеет

- Устанавливать и обновлять Zapret и его LuCI-пакет через `apk` или `opkg`.
- Загружать пресеты Flowseal и стратегии Zapret Manager.
- Собирать основную стратегию, YouTube, Discord и игры. К Flowseal, включая ALT9, можно добавить игровой профиль.
- Показывать применённые стратегии, ручные изменения и обновления каталога.
- Управлять доменами, исключениями устройств, автозапуском и резервными копиями.
- Проверять доступность сайтов, сравнивать стратегии и запускать blockcheck.
- Обновлять сам JZM из этого репозитория, сохраняя предыдущую сборку.

Изменения конфигурации выполняются с резервным снимком и откатом при ошибке.
Установка системных пакетов проходит отдельно: их базу менеджер назад не откатывает.

## Разработка

Стек: **ucode + POSIX sh**, сборка через **just**. Работайте в Linux или WSL2;
в WSL держите проект в домашнем каталоге Linux.

```sh
git clone https://github.com/swxfe/just-zapret-manager.git
cd just-zapret-manager
sudo apt-get update
sudo apt-get install -y git build-essential cmake ninja-build pkg-config libjson-c-dev libpcre2-dev shellcheck curl unzip python3 just
sh tools/setup-dev.sh
export PATH="$HOME/.local/share/jzm-dev/openwrt-25.12/bin:$PATH"
just bundle
```

Если в вашем дистрибутиве нет пакета `just`, установите его по
[официальной инструкции](https://just.systems/man/en/packages.html).
`tools/setup-dev.sh` собирает закреплённые версии ucode и UCI локально в `~/.local/share/jzm-dev/`.

| Команда | Результат |
| --- | --- |
| `just check` | Синтаксис shell, компиляция ucode и ShellCheck |
| `just test` | Все локальные тесты и самопроверка обвязки эмулятора |
| `just bundle` | Тесты и сборка `dist/just-zapret-manager.sh` |
| `just emulator-setup` | Загрузка эмулятора и подготовка OpenWrt |
| `just test-e2e` | Сборка и полный прогон на виртуальном роутере |

Эмулятор требует Linux x86_64, Python 3, SSH/SCP, `unzip` и `zstd`.
В Ubuntu: `sudo apt-get install -y openssh-client unzip zstd`.
Образы лежат в игнорируемой `.emulator/`, отчёты — в `.test-tmp/e2e/`.
Каждый E2E-прогон использует отдельную копию Flash.

```text
src/       ucode-библиотеки, точка входа и shell-бэкенд
data/      встроенные стратегии, списки и настройки
tools/     сборка, установщик и инструменты разработки
tests/     модульные, интеграционные и E2E-тесты
dist/      готовый читаемый скрипт для роутера
```

Готовая сборка содержит исходники и данные обычным текстом; распаковка при запуске не нужна.
Пользовательский вход — `jzm` без аргументов. Для тестов и автоматизации существует
внутренний протокол: `JZM_MODE=command /usr/bin/jzm <команда>`.
Перед изменениями прочитайте [AGENTS.md](AGENTS.md); дополнительная матрица ucode запускается через `sh tools/test-matrix.sh`.

## Благодарности

- [bol-van/zapret](https://github.com/bol-van/zapret) — ядро обхода DPI.
- [StressOzz/Zapret-Manager](https://github.com/StressOzz/Zapret-Manager) — исходный менеджер, каталог стратегий и списки.
- [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) — пресеты Flowseal.
- [remittor/zapret-openwrt](https://github.com/remittor/zapret-openwrt) — пакеты Zapret и LuCI для OpenWrt.
- [stavultras/router-emulator](https://github.com/stavultras/router-emulator) — виртуальный роутер для E2E.
- [OpenWrt](https://openwrt.org/) и [ucode](https://github.com/ucode-lang/ucode) — платформа и инструменты.

## Лицензия

Проект распространяется под лицензией [GNU General Public License v3.0 (GPL-3.0)](https://www.gnu.org/licenses/gpl-3.0.html). Подробности смотрите в файле [LICENSE](LICENSE).