# Установка и работа с just-zapret-manager

Нужны OpenWrt с `apk` или `opkg`, доступ по SSH от `root`, интернет и свободное место во Flash.
Менеджер работает с **Zapret первого поколения** и пакетом `luci-app-zapret`.

## Одной командой

Выполните в SSH-сессии роутера:

```sh
wget -O /tmp/jzm-install.sh https://raw.githubusercontent.com/swxfe/just-zapret-manager/main/tools/bootstrap.sh && sh /tmp/jzm-install.sh
```

Установщик проверяет среду и место перед установкой зависимостей, скачивает готовую сборку,
устанавливает `/usr/bin/jzm` и открывает меню. Сам Zapret установите через
**«Установка / обновление / удаление» → «Установить Zapret»**.
Рекомендуемый источник — сборка remittor с LuCI.

Последующие запуски:

```sh
jzm
```

## Ручная установка

Если зависимости `ucode`, `ucode-mod-fs ucode-mod-uci ucode-mod-ubus ucode-mod-digest ucode-mod-uclient ucode-mod-uloop`, `uci`, `curl`, `ca-bundle` и `unzip` уже установлены:

```sh
wget -O /tmp/just-zapret-manager.sh https://raw.githubusercontent.com/swxfe/just-zapret-manager/main/dist/just-zapret-manager.sh
JZM_MODE=command sh /tmp/just-zapret-manager.sh manager-install
jzm
```

Команда `jzm` создаётся установщиком автоматически; отдельного пункта для неё в меню нет.

## Возможности

- Устанавливать и обновлять Zapret и его LuCI-пакет через `apk` или `opkg`.
- Загружать пресеты Flowseal и стратегии Zapret Manager.
- Собирать основную стратегию, YouTube, Discord и игры. К Flowseal, включая ALT9, можно добавить игровой профиль.
- Показывать применённые стратегии, ручные изменения и обновления каталога.
- Управлять доменами, исключениями устройств, автозапуском и резервными копиями.
- Проверять доступность сайтов, сравнивать стратегии и запускать blockcheck.
- Обновлять сам JZM из этого репозитория, сохраняя предыдущую сборку.


## Стратегии

Откройте **«Стратегии»**: выберите Flowseal или соберите профиль из отдельных групп.
Чтобы дополнить Flowseal ALT9 игровым профилем, сначала примените ALT9, затем откройте
**«Собрать: основная + YouTube + Discord + игры» → «Игры»** и выберите `Gv1`–`Gv4`.
Flowseal останется в композиции; игровой профиль можно заменить или отключить там же.
Работоспособность пресета зависит от провайдера — проверяйте результат на своей сети.

## Обновления и данные

JZM проверяет сборку в `swxfe/just-zapret-manager`, ветка `main`.
Проверку и установку можно запустить пунктом **«Проверить обновления менеджера»**.
Предыдущий исполняемый файл сохраняется в `/usr/bin/jzm.previous`.
Чтобы перейти со старой экспериментальной версии 10.x на релиз 0.1, повторите команду установки выше.

| Путь | Назначение |
| --- | --- |
| `/usr/bin/jzm` | Менеджер |
| `/etc/zapret-manager/` | Настройки, состояние, каталоги и резервные копии JZM |
| `/etc/zapret-manager/backups/` | Резервные копии по умолчанию |
| `/etc/config/zapret` | Конфигурация Zapret для LuCI |
| `/opt/zapret/` | Zapret, списки, fake-файлы и хуки |

Резервные копии нужны перед экспериментами. Перед полным удалением сохраните нужные копии на ПК.

## Удаление

В **«Установка / обновление / удаление»** доступны:

- **Удалить только JZM** — убирает менеджер, его данные и резервные копии, расписание,
  правило QUIC и хук исключений JZM; восстанавливает сохранённые настройки offloading.
  Zapret, LuCI, выбранные стратегии и необходимые им файлы остаются.
- **Удалить всё: JZM + Zapret + LuCI** — дополнительно удаляет оба пакета,
  `/etc/config/zapret` и `/opt/zapret/` со всеми списками и fake-файлами.
- **Удалить Zapret** — удаляет пакеты, оставляя JZM для последующей установки.

Удаление требует подтверждения `[y/N]`. Зависимости общего назначения (`curl`, `ucode`, UCI)
сохраняются: они могут использоваться самой OpenWrt и другими приложениями.

## Устройство и безопасность

Изменения конфигурации выполняются с резервным снимком и откатом при ошибке.
Установка системных пакетов проходит отдельно: их базу менеджер назад не откатывает.

Меню работает в одном процессе ucode: настройки читаются через `uci`, состояние procd —
через `ubus`, SHA256 — через `digest`, HTTP/TLS — через `uclient` и `uloop`.
Каталоги, пакетные версии и состояние конфигурации сохраняются в памяти сессии.
Кэш сбрасывается после подтверждённого commit; отмена, ошибка и успешный откат его сохраняют.
Проверка обновлений JZM запускается явно пунктом **«Проверить обновления менеджера»**.

Нужны модули `ucode-mod-fs`, `ucode-mod-uci`, `ucode-mod-ubus`, `ucode-mod-digest`,
`ucode-mod-uclient`, `ucode-mod-uloop` и CA bundle. Установщик проверяет весь набор.
Независимый POSIX sh супервизор хранит снимки, обрабатывает сигналы, проверяет Flash
и восстанавливает состояние при отказе worker. Штатные init/sync/blockcheck-скрипты Zapret
остаются интерфейсом интеграции с самим пакетом.

## Разработка

Стек: **ucode + POSIX sh**, сборка через **just**. Работайте в Linux или WSL2;
в WSL держите проект в домашнем каталоге Linux.

```sh
git clone https://github.com/swxfe/just-zapret-manager.git
cd just-zapret-manager
sudo apt-get update
sudo apt-get install -y git build-essential cmake ninja-build pkg-config libjson-c-dev libpcre2-dev libmd-dev libssl-dev shellcheck curl unzip python3 just
sh tools/setup-dev.sh
export PATH="$HOME/.local/share/jzm-dev/openwrt-25.12/bin:$PATH"
just bundle
```

Если в вашем дистрибутиве нет пакета `just`, установите его по
[официальной инструкции](https://just.systems/man/en/packages.html).
`tools/setup-dev.sh` собирает закреплённые версии ucode, UCI, ubus и HTTP/TLS-библиотек локально в `~/.local/share/jzm-dev/`.

| Команда | Результат |
| --- | --- |
| `just check` | Синтаксис shell, компиляция ucode и ShellCheck |
| `just test` | Все локальные тесты, HTTP/TLS, проверка кэша и отсутствия fork в UI и самопроверка обвязки эмулятора |
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
tests/     наборы тестов, mocks/, setup/ и fixtures/ (см. tests/README.md)
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
