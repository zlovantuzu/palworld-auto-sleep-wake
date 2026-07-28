# Palworld Auto Sleep / Wake

*[English version](README.en.md)*

Локальная автоматизация для Palworld Dedicated Server под Linux:

- корректно сохраняет мир;
- выключает сервер после заданного времени без игроков;
- запускает сервер при входящем UDP-пакете на игровой порт;
- работает через `systemd`;
- не использует Discord-ботов, облачные сервисы, внешние API или сторонние интеграции.

Изначально схема проверялась на Palworld Dedicated Server `v1.0.1.100619`.

## Как это работает

```text
Игроки есть
    ↓
Palworld работает
    ↓
Игроков нет заданное время
    ↓
POST /v1/api/save
    ↓
POST /v1/api/shutdown
    ↓
Palworld выключен
    ↓
Приходит UDP-пакет на игровой порт
    ↓
systemctl start palworld.service
    ↓
Игрок повторно подключается после загрузки сервера
```

## Важное ограничение

Полностью выключенный Palworld не может сразу принять подключение.

Первая попытка подключения отправляет UDP-пакет и запускает сервер. После загрузки Palworld игроку обычно нужно повторить подключение. Сервер также не будет отображаться как доступный в публичном списке, пока он выключен.

Машина, виртуальная машина или контейнер должны продолжать работать. Автоматизация выключает только процесс Palworld.

## Состав проекта

```text
.
├── config/
│   └── palworld-auto.conf.example
├── scripts/
│   ├── palworld-idle-watch
│   ├── palworld-run
│   └── palworld-wake
├── systemd/
│   ├── palworld-idle.service
│   ├── palworld-wake.service
│   └── palworld.service.in
├── install.sh
├── uninstall.sh
├── LICENSE
└── README.md
```

## Требования

- Linux с `systemd`;
- Palworld Dedicated Server;
- `curl`;
- `jq`;
- `tcpdump`;
- права `root` для установки;
- включённый локальный REST API Palworld.

На Ubuntu/Debian зависимости устанавливаются автоматически установщиком. Вручную:

```bash
sudo apt update
sudo apt install -y curl jq tcpdump
```

## Быстрый старт

Полный путь от чистой машины до работающей автоматизации, по порядку:

1. [Установи Palworld Dedicated Server](#установка-palworld-dedicated-server) (SteamCMD).
2. [Включи REST API](#настройка-palworld-rest-api) в `PalWorldSettings.ini` и задай `AdminPassword`.
3. [Установи эту автоматизацию](#установка) через `sudo ./install.sh ...`.
4. Если пароль не был введён при установке — задай его отдельно (см. вывод установщика).
5. [Запусти все службы](#запустить-всё).
6. [Проверь REST API](#проверка-rest-api) и статусы служб.

Чтобы приостановить или полностью выключить автоматизацию — см. [Остановить всё](#остановить-всё).

Каждый шаг подробно описан в соответствующем разделе ниже.

## Установка Palworld Dedicated Server

Этот репозиторий не устанавливает сам Palworld — только автоматизацию сна/пробуждения. Сервер нужно установить заранее, а каталог установки указать как `--palworld-dir` при установке (см. ниже), чтобы пути совпадали.

Установи SteamCMD (официальная инструкция Valve): <https://developer.valvesoftware.com/wiki/SteamCMD>

Установи или обнови Palworld Dedicated Server в конкретный каталог (анонимный логин, `app_update 2394010` — это Palworld Dedicated Server):

```bash
mkdir -p /home/server/palworld

steamcmd \
  +force_install_dir /home/server/palworld \
  +login anonymous \
  +app_update 2394010 validate \
  +quit
```

Та же команда используется и для обновления сервера.

После установки каталог выглядит так:

```text
/home/server/palworld/
├── PalServer.sh
├── DefaultPalWorldSettings.ini
└── Pal/
    ├── Binaries/Linux/PalServer-Linux-Shipping
    └── Saved/
        ├── Config/LinuxServer/PalWorldSettings.ini
        └── SaveGames/
```

Именно этот каталог передавай в `--palworld-dir` / `PALWORLD_DIR`. Скрипт запуска (`START_SCRIPT`) по умолчанию — `./start.sh`. Если ты не используешь собственную обёртку с таким именем, укажи официальный бинарник напрямую:

```bash
sudo ./install.sh \
  --user server \
  --palworld-dir /home/server/palworld \
  --start-script ./PalServer.sh
```

Официальная инструкция по развёртыванию выделенного сервера: <https://docs.palworldgame.com/getting-started/deploy-dedicated-server/>

### Скрипт запуска (`start.sh`)

Если `START_SCRIPT` не найден по указанному пути, `install.sh` в интерактивном терминале сам предложит его создать и спросит игровой UDP-порт и лимит игроков (по умолчанию `42365` и `32`). Введённый порт также подставится в `GAME_PORT` создаваемого `/etc/palworld-auto/config`, чтобы `palworld-wake` слушал тот же порт. В неинтерактивном запуске (например, из другого скрипта) при отсутствующем файле установка просто завершится ошибкой.

Если хочешь запускать сервер с параметрами (порт, лимит игроков, многопоточность), а не голым `./PalServer.sh`, можешь и сам создать `start.sh` в `PALWORLD_DIR` и сделать его исполняемым (`chmod +x`) — установщик использует именно такой шаблон:

```bash
#!/usr/bin/env bash
exec ./PalServer.sh \
  -port=42365 \
  -players=32 \
  -useperfthreads \
  -NoAsyncLoadingThread \
  -UseMultithreadForDS
```

`-port` должен совпадать с `GAME_PORT` в `/etc/palworld-auto/config`, иначе `palworld-wake` будет слушать не тот порт. `exec` заменяет процесс bash процессом `PalServer.sh`, чтобы `systemd` управлял именно игровым сервером, а не лишней обёрткой.

Официально задокументированные аргументы командной строки: <https://docs.palworldgame.com/settings-and-operation/arguments/>

| Флаг | Назначение |
|---|---|
| `-port=8211` | UDP-порт сервера |
| `-players=32` | Максимум игроков |
| `-useperfthreads` `-NoAsyncLoadingThread` `-UseMultithreadForDS` | Рекомендованная официальная связка для многопоточности (используются вместе) |
| `-NumberOfWorkerThreadsServer=N` | Число рабочих потоков |
| `-publiclobby` | Сделать сервер community-сервером |
| `-publicip=x.x.x.x`, `-publicport=xxxx` | Явно задать публичные IP/порт |
| `-logformat=text\|json` | Формат логов |

`ServerName`, `ServerPassword` и `AdminPassword` **не документированы как аргументы командной строки** — задавай их только внутри `OptionSettings=(...)` в `PalWorldSettings.ini` (см. ниже), а не флагами `start.sh`.

## Настройка Palworld REST API

Открой:

```bash
nano /home/server/palworld/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini
```

Если файла ещё нет, создай его из шаблона (правка `DefaultPalWorldSettings.ini` не действует):

```bash
cp /home/server/palworld/DefaultPalWorldSettings.ini \
   /home/server/palworld/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini
```

Весь файл — одна строка вида (значения ниже сокращены для примера, полный список — по ссылке ниже):

```ini
[/Script/Pal.PalGameWorldSettings]
OptionSettings=(Difficulty=None,DayTimeSpeedRate=1.000000,ExpRate=1.000000,ServerName="My Palworld Server",ServerDescription="",AdminPassword="СЛОЖНЫЙ_ПАРОЛЬ",ServerPassword="",PublicPort=8211,PublicIP="",RCONEnabled=False,RCONPort=25575,RESTAPIEnabled=True,RESTAPIPort=8212,ServerPlayerMaxNum=32)
```

Обязательно должны присутствовать внутри `OptionSettings=(...)` (без переносов строк):

```ini
AdminPassword="СЛОЖНЫЙ_ПАРОЛЬ"
RESTAPIEnabled=True
RESTAPIPort=8212
```

Не открывай порт REST API `8212` в интернет. Скрипты обращаются к нему только через `127.0.0.1`.

Полный список параметров и их описание: <https://docs.palworldgame.com/settings-and-operation/configuration/>

Официальная документация по REST API:

- [Palworld REST API](https://docs.palworldgame.com/api/rest-api/palwold-rest-api/)
- [Save API](https://docs.palworldgame.com/api/rest-api/save/)
- [Shutdown API](https://docs.palworldgame.com/api/rest-api/shutdown/)

### Быстрые команды для правки конфига

Останови сервер перед правкой:

```bash
sudo systemctl stop palworld.service
```

Задай путь один раз:

```bash
CONFIG="/home/server/palworld/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini"
```

Поменять пароль администратора:

```bash
sudo sed -i -E \
  's/AdminPassword="[^"]*"/AdminPassword="НОВЫЙ_ПАРОЛЬ"/' \
  "$CONFIG"
```

Включить REST API и задать его порт:

```bash
sudo sed -i -E 's/RESTAPIEnabled=(True|False)/RESTAPIEnabled=True/' "$CONFIG"
sudo sed -i -E 's/RESTAPIPort=[0-9]+/RESTAPIPort=8212/' "$CONFIG"
```

Проверить текущие значения без раскрытия пароля:

```bash
sudo grep -oE \
  'AdminPassword="[^"]*"|RESTAPIEnabled=(True|False)|RESTAPIPort=[0-9]+' \
  "$CONFIG" |
sed -E 's/AdminPassword="[^"]*"/AdminPassword="***"/'
```

Если менял пароль или порт REST API, обнови их и в автоматизации:

```bash
sudo sh -c 'umask 077; printf "%s\n" "НОВЫЙ_ПАРОЛЬ" > /etc/palworld-auto/admin-password'
sudo nano /etc/palworld-auto/config   # REST_PORT, если меняли RESTAPIPort
sudo systemctl restart palworld-idle.service
```

## Установка

Сначала останови сервер, если он запущен вручную:

```bash
pgrep -af PalServer
```

В терминале запущенного сервера нажми `Ctrl+C`.

Затем:

```bash
git clone https://github.com/zlovantuzu/palworld-auto-sleep-wake
cd palworld-auto-sleep-wake

sudo ./install.sh \
  --user server \
  --palworld-dir /home/server/palworld
```

Инсталлятор:

1. проверит зависимости;
2. установит скрипты в `/usr/local/lib/palworld-auto`;
3. создаст конфигурацию в `/etc/palworld-auto/config`;
4. создаст защищённый файл пароля;
5. установит `systemd` units;
6. включит службы сна и пробуждения.

При интерактивном запуске установщик предложит ввести `AdminPassword`. Ввод скрыт.

Если пароль был пропущен:

```bash
sudo sh -c 'umask 077; printf "%s\n" "ВАШ_ADMIN_PASSWORD" > /etc/palworld-auto/admin-password'
sudo systemctl enable --now palworld-idle.service
```

## Конфигурация

Основной файл:

```bash
sudo nano /etc/palworld-auto/config
```

Пример:

```bash
PALWORLD_DIR="/home/server/palworld"
START_SCRIPT="./start.sh"

GAME_PORT=42365

REST_HOST="127.0.0.1"
REST_PORT=8212
REST_USER="admin"
PASSWORD_FILE="/etc/palworld-auto/admin-password"

IDLE_SECONDS=900
POLL_SECONDS=30
LOG_EVERY_SECONDS=300

SHUTDOWN_WAIT_SECONDS=30
SHUTDOWN_TIMEOUT_SECONDS=120
SHUTDOWN_MESSAGE="Server is empty and will shut down."
FORCE_STOP_AFTER_TIMEOUT=true

TCPDUMP_INTERFACE="any"
WAKE_COOLDOWN_SECONDS=60
```

### Основные параметры

| Параметр | Значение |
|---|---|
| `PALWORLD_DIR` | Каталог сервера Palworld |
| `START_SCRIPT` | Скрипт запуска относительно `PALWORLD_DIR` или абсолютный путь |
| `GAME_PORT` | Фактический UDP-порт игрового сервера |
| `REST_PORT` | Локальный порт REST API |
| `IDLE_SECONDS` | Через сколько секунд без игроков выключать сервер |
| `POLL_SECONDS` | Интервал проверки числа игроков |
| `SHUTDOWN_WAIT_SECONDS` | Задержка штатного выключения Palworld |
| `FORCE_STOP_AFTER_TIMEOUT` | Принудительно остановить unit, если REST shutdown завис |
| `WAKE_COOLDOWN_SECONDS` | Пауза после запуска, защищающая от повторных стартов |

После изменения конфигурации:

```bash
sudo systemctl restart palworld-idle.service
sudo systemctl restart palworld-wake.service
```

## Управление службами

Установщик сам включает `palworld-wake.service` и (если задан пароль) `palworld-idle.service`. Ниже — сводные команды, чтобы поднять или остановить всё сразу, а после них — управление каждым юнитом по отдельности.

Если команды из этого раздела падают с ошибкой вида `Unit file palworld-idle.service does not exist`, значит `sudo ./install.sh ...` ещё не запускался (или упал с ошибкой) — юниты в `/etc/systemd/system` не появляются сами по себе из склонированного репозитория. См. [Установка](#установка) и раздел [Типичные проблемы](#unit-file-palworld-idleservice-does-not-exist).

### Запустить всё

Если автоматизация уже установлена (см. [Установка](#установка)), но службы не запущены:

```bash
sudo systemctl enable --now palworld-wake.service
sudo systemctl enable --now palworld-idle.service   # только если задан admin-password
```

Сам игровой сервер поднимать вручную не обязательно — `palworld-wake.service` запустит его при первом UDP-пакете. Но можно и сразу:

```bash
sudo systemctl start palworld.service
```

Проверить, что всё работает:

```bash
systemctl status palworld-wake.service palworld-idle.service palworld.service
```

Ожидается: `palworld-wake` и `palworld-idle` — `active (running)`. `palworld` — `active (running)`, если запускал вручную, либо `inactive (dead)` до первого подключения (это нормально, см. [Важное ограничение](#важное-ограничение)).

### Остановить всё

Приостановить автоматизацию, не трогая запущенный сервер:

```bash
sudo systemctl disable --now palworld-idle.service
sudo systemctl disable --now palworld-wake.service
```

Дополнительно остановить сам игровой сервер:

```bash
sudo systemctl stop palworld.service
```

После этого ни выключение при простое, ни пробуждение по UDP работать не будут, пока службы не включишь заново (см. [Запустить всё](#запустить-всё) выше).

### Игровой сервер (`palworld.service`)

Запустить:

```bash
sudo systemctl start palworld.service
```

Остановить:

```bash
sudo systemctl stop palworld.service
```

Статус:

```bash
systemctl status palworld.service
```

`palworld.service` намеренно не включается в обычный автозапуск. После перезагрузки машины сервер остаётся выключенным до первой попытки подключения.

Проверка:

```bash
systemctl is-enabled palworld.service
```

Ожидается:

```text
disabled
```

### Автовыключение при простое (`palworld-idle.service`)

```bash
sudo systemctl enable --now palworld-idle.service   # включить в автозапуск и запустить сейчас
sudo systemctl restart palworld-idle.service        # применить изменения конфигурации
sudo systemctl disable --now palworld-idle.service  # остановить и убрать из автозапуска
systemctl status palworld-idle.service
```

### Пробуждение по UDP (`palworld-wake.service`)

```bash
sudo systemctl enable --now palworld-wake.service
sudo systemctl restart palworld-wake.service
sudo systemctl disable --now palworld-wake.service
systemctl status palworld-wake.service
```

## Проверка REST API

```bash
PW="$(sudo cat /etc/palworld-auto/admin-password)"

curl -fsS \
  -u "admin:${PW}" \
  http://127.0.0.1:8212/v1/api/metrics |
jq

unset PW
```

Пример ответа:

```json
{
  "serverfps": 60,
  "currentplayernum": 0,
  "serverframetime": 16.6,
  "maxplayernum": 32,
  "uptime": 100
}
```

## Проверка автоматического выключения

Временно установи:

```bash
IDLE_SECONDS=180
```

Перезапусти watcher:

```bash
sudo systemctl restart palworld-idle.service
sudo journalctl -fu palworld-idle.service
```

Пустой сервер должен:

1. дождаться трёх минут;
2. повторно проверить число игроков;
3. вызвать `/save`;
4. вызвать `/shutdown`;
5. перейти в состояние `inactive`.

После теста верни, например:

```bash
IDLE_SECONDS=900
```

## Проверка пробуждения

Останови сервер:

```bash
sudo systemctl stop palworld.service
```

Отправь тестовый UDP-пакет:

```bash
echo wake | nc -u -w1 127.0.0.1 42365
```

Если `nc` отсутствует:

```bash
sudo apt install -y netcat-openbsd
```

Проверь:

```bash
systemctl status palworld.service
```

Для реальной проверки попробуй подключиться из игры по IP и порту. Первая попытка запускает сервер, следующая выполняется после его загрузки.

## Перенос локального (кооп) сейва на выделенный сервер

Локальный (co-op) сейв Palworld не запустится на dedicated-сервере напрямую — нужен конвертер:

<https://hub.tcno.co/games/palworld/converter/>

Инструмент работает в браузере, без загрузки файлов на сторонний сервер. Загрузи туда каталог локального сейва (в частности `Level.sav` и папку с сейвами игроков), получи ZIP с конвертированными файлами.

Куда класть результат на сервере:

1. Останови сервер:

   ```bash
   sudo systemctl stop palworld.service
   ```

2. Найди каталог текущего мира — это подпапка с длинным hex-идентификатором внутри `SaveGames`:

   ```bash
   find /home/server/palworld/Pal/Saved/SaveGames -mindepth 2 -maxdepth 2 -type d
   ```

   Если сервер ни разу не запускался, сначала запусти его один раз и останови — так появится каталог `Pal/Saved/SaveGames/0/<ID_МИРА>/` с шаблоном файлов (`Level.sav`, `LevelMeta.sav`, `WorldOption.sav`, `Players/`).

3. Сделай резервную копию перед заменой:

   ```bash
   sudo cp -a /home/server/palworld/Pal/Saved/SaveGames \
             /home/server/palworld/Pal/Saved/SaveGames.bak
   ```

4. Распакуй ZIP от конвертера в найденный каталог мира, заменив существующие файлы (`Level.sav`, файлы игроков и т.д.), как указано на странице конвертера.

5. Верни владельца файлов пользователю, от которого работает Palworld:

   ```bash
   sudo chown -R server:server /home/server/palworld/Pal/Saved/SaveGames
   ```

6. Запусти сервер и проверь логи:

   ```bash
   sudo systemctl start palworld.service
   sudo journalctl -fu palworld.service
   ```

## Логи

Все компоненты:

```bash
sudo journalctl \
  -u palworld.service \
  -u palworld-idle.service \
  -u palworld-wake.service \
  -f
```

Только выключение:

```bash
sudo journalctl -fu palworld-idle.service
```

Только пробуждение:

```bash
sudo journalctl -fu palworld-wake.service
```

Только игровой сервер:

```bash
sudo journalctl -fu palworld.service
```

## Типичные проблемы

### `Unit file palworld-idle.service does not exist`

`systemctl enable/start/status` не находит юнит. Это значит, что автоматизация ещё не установлена в `/etc/systemd/system` — файлы `systemd/*.service` в склонированном репозитории сами по себе ни на что не влияют, их должен скопировать установщик.

Проверь, что юниты реально установлены:

```bash
systemctl list-unit-files | grep palworld
```

Если пусто — запусти установщик из корня репозитория (не из подкаталога `systemd/`):

```bash
cd ~/palworld-auto-sleep-wake
sudo ./install.sh --user server --palworld-dir /home/server/palworld
```

Внимательно прочитай вывод команды: если установщик упал с ошибкой (например, зависимости, несуществующий пользователь или каталог), юниты не установятся. Затем повтори [Запустить всё](#запустить-всё).

### `Unauthorized (AdminPassword is empty)`

Palworld запущен с пустым административным паролем, даже если пароль виден в `PalWorldSettings.ini`.

Проверь:

- редактируется ли правильный файл;
- находится ли `AdminPassword` внутри `OptionSettings=(...)`;
- полностью ли перезапущен сервер;
- нет ли `WorldOption.sav`, переопределяющего параметры.

Поиск:

```bash
find /home/server/palworld/Pal/Saved/SaveGames \
  -type f -iname 'WorldOption.sav' -print
```

Перед отключением файла сделай резервную копию:

```bash
find /home/server/palworld/Pal/Saved/SaveGames \
  -type f -iname 'WorldOption.sav' \
  -exec mv -v {} {}.bak \;
```

### `/save` возвращает `411 missing_content_length_header`

Palworld требует `Content-Length: 0` для пустого POST-запроса. Скрипт уже учитывает это через:

```bash
--data ''
```

Не заменяй этот вызов на одинокий `-X POST`.

### `/shutdown` возвращает `400 Bad Request`

У запроса должно быть только одно JSON-тело:

```json
{
  "waittime": 30,
  "message": "Server is empty and will shut down."
}
```

Несколько параметров `--data` объединяются `curl` и повреждают JSON. В готовом скрипте используется один `--data-raw`.

### Сервер запускается от случайных пакетов

Любой входящий UDP-пакет на игровой порт может разбудить сервер, включая сканирование портов.

Варианты:

- ограничить доступ firewall;
- разрешить только известные IP;
- использовать VPN;
- увеличить `WAKE_COOLDOWN_SECONDS`.

### Сервер запустился, но подключение не прошло

Это ожидаемо. Первый пакет только запускает процесс. Подожди загрузку Palworld и повтори подключение.

### `tcpdump` ничего не видит

Проверь фактический порт:

```bash
sudo ss -lunp | grep PalServer
```

Проверь трафик вручную:

```bash
sudo tcpdump -ni any "udp dst port 42365"
```

Убедись, что UDP-порт проброшен на роутере и разрешён firewall.

## Обновление

```bash
git pull
sudo ./install.sh \
  --user server \
  --palworld-dir /home/server/palworld
```

Существующие `/etc/palworld-auto/config` и пароль не перезаписываются.

## Удаление

Удалить службы и скрипты, сохранив конфигурацию:

```bash
sudo ./uninstall.sh
```

Удалить также `/etc/palworld-auto`:

```bash
sudo ./uninstall.sh --purge
```

Сохранения, конфигурация и файлы Palworld не удаляются.

## Безопасность

- не публикуй `/etc/palworld-auto/admin-password`;
- не добавляй пароль в репозиторий;
- не открывай REST API наружу;
- не используй `curl -v` с реальным паролем: verbose-вывод может показать Basic Auth заголовок;
- ограничивай игровой порт firewall, если сервер предназначен только для знакомых игроков.

## Лицензия

MIT.
