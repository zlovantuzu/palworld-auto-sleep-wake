# Palworld Auto Sleep / Wake

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

## Настройка Palworld REST API

Открой:

```bash
nano /home/server/palworld/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini
```

Внутри `OptionSettings=(...)` должны присутствовать:

```ini
AdminPassword="СЛОЖНЫЙ_ПАРОЛЬ"
RESTAPIEnabled=True
RESTAPIPort=8212
```

Не открывай порт REST API `8212` в интернет. Скрипты обращаются к нему только через `127.0.0.1`.

Официальная документация:

- [Palworld REST API](https://docs.palworldgame.com/api/rest-api/palwold-rest-api/)
- [Save API](https://docs.palworldgame.com/api/rest-api/save/)
- [Shutdown API](https://docs.palworldgame.com/api/rest-api/shutdown/)

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

## Управление сервером

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
