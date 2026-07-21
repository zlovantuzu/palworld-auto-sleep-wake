# Palworld Auto Sleep / Wake

*[Русская версия](README.md)*

Local automation for a Palworld Dedicated Server on Linux:

- saves the world correctly;
- shuts the server down after a configurable idle period with no players;
- starts the server on an incoming UDP packet to the game port;
- runs entirely through `systemd`;
- uses no Discord bots, cloud services, external APIs, or third-party integrations.

The setup was originally validated against Palworld Dedicated Server `v1.0.1.100619`.

## How it works

```text
Players connected
    ↓
Palworld running
    ↓
No players for the configured time
    ↓
POST /v1/api/save
    ↓
POST /v1/api/shutdown
    ↓
Palworld stopped
    ↓
A UDP packet arrives on the game port
    ↓
systemctl start palworld.service
    ↓
Player reconnects once the server has loaded
```

## Important limitation

A fully stopped Palworld cannot accept a connection immediately.

The first connection attempt sends a UDP packet and starts the server. After Palworld finishes loading, the player usually has to reconnect. The server will also not appear as available in the public list while it is stopped.

The machine, virtual machine, or container must keep running. The automation only stops the Palworld process, not the host.

## Project layout

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

### Components

| Component | Role |
|---|---|
| `palworld-run` | Launches the actual server (`Type=simple`, `exec`s your start script). Runs as the non-root Palworld user. |
| `palworld-idle-watch` | Polls the REST API for the player count and gracefully saves + shuts down after `IDLE_SECONDS` with no players. Runs as root. |
| `palworld-wake` | Watches for an incoming UDP packet on the game port with `tcpdump` and runs `systemctl start` to bring the server back. Runs as root. |
| `palworld.service` | The game server unit. Deliberately **not** enabled at boot. |

## Requirements

- Linux with `systemd`;
- Palworld Dedicated Server;
- `curl`;
- `jq`;
- `tcpdump`;
- `root` privileges for installation;
- the local Palworld REST API enabled.

On Ubuntu/Debian the dependencies are installed automatically by the installer. Manually:

```bash
sudo apt update
sudo apt install -y curl jq tcpdump
```

## Configuring the Palworld REST API

Open:

```bash
nano /home/server/palworld/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini
```

Inside `OptionSettings=(...)` you need:

```ini
AdminPassword="STRONG_PASSWORD"
RESTAPIEnabled=True
RESTAPIPort=8212
```

Do not expose the REST API port `8212` to the internet. The scripts only reach it through `127.0.0.1`.

Official documentation:

- [Palworld REST API](https://docs.palworldgame.com/api/rest-api/palwold-rest-api/)
- [Save API](https://docs.palworldgame.com/api/rest-api/save/)
- [Shutdown API](https://docs.palworldgame.com/api/rest-api/shutdown/)

## Installation

First stop the server if it is running by hand:

```bash
pgrep -af PalServer
```

In the running server's terminal, press `Ctrl+C`.

Then:

```bash
git clone https://github.com/zlovantuzu/palworld-auto-sleep-wake.git
cd palworld-auto-sleep-wake

sudo ./install.sh \
  --user server \
  --palworld-dir /home/server/palworld
```

If your launcher is not `./start.sh`, point the installer at it:

```bash
sudo ./install.sh \
  --user server \
  --palworld-dir /home/server/palworld \
  --start-script ./my-start.sh
```

The installer:

1. checks dependencies;
2. installs the scripts into `/usr/local/lib/palworld-auto`;
3. creates the configuration in `/etc/palworld-auto/config`;
4. creates a protected password file;
5. installs the `systemd` units;
6. enables the sleep and wake services.

When run interactively, the installer prompts for the `AdminPassword`. Input is hidden.

If the password was skipped:

```bash
sudo sh -c 'umask 077; printf "%s\n" "YOUR_ADMIN_PASSWORD" > /etc/palworld-auto/admin-password'
sudo systemctl enable --now palworld-idle.service
```

### Installer options

| Option | Meaning |
|---|---|
| `--user USER` | Linux user that runs Palworld (default: `server`) |
| `--group GROUP` | Linux group (default: the user's primary group) |
| `--palworld-dir PATH` | Palworld directory |
| `--start-script PATH` | Start script, relative to the Palworld directory or absolute (default: `./start.sh`) |
| `--no-install-deps` | Do not install missing apt dependencies |
| `-h, --help` | Show help |

## Configuration

Main file:

```bash
sudo nano /etc/palworld-auto/config
```

Example:

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

### Key parameters

| Parameter | Meaning |
|---|---|
| `PALWORLD_DIR` | Palworld server directory |
| `START_SCRIPT` | Start script, relative to `PALWORLD_DIR` or an absolute path |
| `GAME_PORT` | Actual UDP game port |
| `REST_PORT` | Local REST API port |
| `IDLE_SECONDS` | Seconds with no players before the server is stopped |
| `POLL_SECONDS` | Player-count polling interval |
| `SHUTDOWN_WAIT_SECONDS` | Grace period Palworld waits before the graceful shutdown |
| `SHUTDOWN_TIMEOUT_SECONDS` | How long the watcher waits for the unit to stop before forcing it. Must be greater than `SHUTDOWN_WAIT_SECONDS`. |
| `FORCE_STOP_AFTER_TIMEOUT` | Force `systemctl stop` if the REST shutdown hangs |
| `WAKE_COOLDOWN_SECONDS` | Pause after a start, guarding against repeated starts |

After changing the configuration:

```bash
sudo systemctl restart palworld-idle.service
sudo systemctl restart palworld-wake.service
```

### Permissions

The config directory `/etc/palworld-auto` is `0755` and `config` is `0644`, so the non-root Palworld user can read it (`palworld-run` sources it at startup). Secrets stay in `admin-password`, which is `0600` and readable only by root. Do not put the admin password in `config`.

## Managing the server

Start:

```bash
sudo systemctl start palworld.service
```

Stop:

```bash
sudo systemctl stop palworld.service
```

Status:

```bash
systemctl status palworld.service
```

`palworld.service` is intentionally left out of normal autostart. After a machine reboot the server stays down until the first connection attempt.

Check:

```bash
systemctl is-enabled palworld.service
```

Expected:

```text
disabled
```

## Checking the REST API

```bash
PW="$(sudo cat /etc/palworld-auto/admin-password)"

curl -fsS \
  -u "admin:${PW}" \
  http://127.0.0.1:8212/v1/api/metrics |
jq

unset PW
```

Example response:

```json
{
  "serverfps": 60,
  "currentplayernum": 0,
  "serverframetime": 16.6,
  "maxplayernum": 32,
  "uptime": 100
}
```

## Testing automatic shutdown

Temporarily set:

```bash
IDLE_SECONDS=180
```

Restart the watcher:

```bash
sudo systemctl restart palworld-idle.service
sudo journalctl -fu palworld-idle.service
```

An empty server should:

1. wait three minutes;
2. re-check the player count;
3. call `/save`;
4. call `/shutdown`;
5. move to the `inactive` state.

After the test restore, e.g.:

```bash
IDLE_SECONDS=900
```

## Testing wake-up

Stop the server:

```bash
sudo systemctl stop palworld.service
```

Send a test UDP packet:

```bash
echo wake | nc -u -w1 127.0.0.1 42365
```

If `nc` is missing:

```bash
sudo apt install -y netcat-openbsd
```

Check:

```bash
systemctl status palworld.service
```

For a real test, try connecting from the game by IP and port. The first attempt starts the server; the next one succeeds after it has loaded.

## Logs

All components:

```bash
sudo journalctl \
  -u palworld.service \
  -u palworld-idle.service \
  -u palworld-wake.service \
  -f
```

Shutdown only:

```bash
sudo journalctl -fu palworld-idle.service
```

Wake-up only:

```bash
sudo journalctl -fu palworld-wake.service
```

Game server only:

```bash
sudo journalctl -fu palworld.service
```

## Common problems

### `Unauthorized (AdminPassword is empty)`

Palworld started with an empty admin password, even if a password is visible in `PalWorldSettings.ini`.

Check:

- that you are editing the right file;
- that `AdminPassword` is inside `OptionSettings=(...)`;
- that the server was fully restarted;
- that there is no `WorldOption.sav` overriding the settings.

Search:

```bash
find /home/server/palworld/Pal/Saved/SaveGames \
  -type f -iname 'WorldOption.sav' -print
```

Back up before disabling the file:

```bash
find /home/server/palworld/Pal/Saved/SaveGames \
  -type f -iname 'WorldOption.sav' \
  -exec mv -v {} {}.bak \;
```

### `/save` returns `411 missing_content_length_header`

Palworld requires `Content-Length: 0` for an empty POST. The script already handles this via:

```bash
--data ''
```

Do not replace that call with a bare `-X POST`.

### `/shutdown` returns `400 Bad Request`

The request must have a single JSON body:

```json
{
  "waittime": 30,
  "message": "Server is empty and will shut down."
}
```

Multiple `--data` options get merged by `curl` and corrupt the JSON. The script uses a single `--data-raw`.

### The server starts from random packets

Any incoming UDP packet on the game port can wake the server, including port scans.

Options:

- restrict access with a firewall;
- allow only known IPs;
- use a VPN;
- increase `WAKE_COOLDOWN_SECONDS`.

### The server started but the connection did not go through

This is expected. The first packet only starts the process. Wait for Palworld to load and reconnect.

### `tcpdump` sees nothing

Check the actual port:

```bash
sudo ss -lunp | grep PalServer
```

Check traffic manually:

```bash
sudo tcpdump -ni any "udp dst port 42365"
```

Make sure the UDP port is forwarded on the router and allowed by the firewall.

## Updating

```bash
git pull
sudo ./install.sh \
  --user server \
  --palworld-dir /home/server/palworld
```

The existing `/etc/palworld-auto/config` and password are not overwritten.

## Uninstalling

Remove services and scripts, keeping the configuration:

```bash
sudo ./uninstall.sh
```

Also remove `/etc/palworld-auto`:

```bash
sudo ./uninstall.sh --purge
```

Saves, configuration, and Palworld files are not deleted.

## Security

- do not publish `/etc/palworld-auto/admin-password`;
- do not commit the password to the repository;
- do not expose the REST API externally;
- do not use `curl -v` with the real password: verbose output can reveal the Basic Auth header;
- the scripts pass credentials to `curl` via a stdin config (`-K -`) rather than `-u`, so the password does not appear in the process argument list;
- restrict the game port with a firewall if the server is meant only for known players.

## License

MIT.
