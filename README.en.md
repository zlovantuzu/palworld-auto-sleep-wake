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

## Quick start

The full path from a clean machine to working automation, in order:

1. [Install the Palworld Dedicated Server](#installing-the-palworld-dedicated-server) (SteamCMD).
2. [Enable the REST API](#configuring-the-palworld-rest-api) in `PalWorldSettings.ini` and set `AdminPassword`.
3. [Install this automation](#installation) via `sudo ./install.sh ...`.
4. If the password wasn't entered during installation, set it separately (see the installer's output).
5. [Start all the services](#start-everything).
6. [Check the REST API](#checking-the-rest-api) and the services' status.

To pause or fully stop the automation, see [Stop everything](#stop-everything).

Each step is described in detail in its own section below.

## Installing the Palworld Dedicated Server

This repository does not install Palworld itself — only the sleep/wake automation. You need to install the server beforehand, and pass its install directory as `--palworld-dir` (see below) so the paths line up.

Install SteamCMD (official Valve guide): <https://developer.valvesoftware.com/wiki/SteamCMD>

Install or update the Palworld Dedicated Server into a fixed directory (anonymous login, `app_update 2394010` is the Palworld Dedicated Server app):

```bash
mkdir -p /home/server/palworld

steamcmd \
  +force_install_dir /home/server/palworld \
  +login anonymous \
  +app_update 2394010 validate \
  +quit
```

The same command is used to update the server later.

After installation the directory looks like this:

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

Pass exactly this directory as `--palworld-dir` / `PALWORLD_DIR`. The start script (`START_SCRIPT`) defaults to `./start.sh`. If you don't have your own wrapper by that name, point it at the official binary directly:

```bash
sudo ./install.sh \
  --user server \
  --palworld-dir /home/server/palworld \
  --start-script ./PalServer.sh
```

Official dedicated server deployment guide: <https://docs.palworldgame.com/getting-started/deploy-dedicated-server/>

### The start script (`start.sh`)

If `START_SCRIPT` isn't found at the configured path, `install.sh` — when run in an interactive terminal — offers to create it and asks for the game's UDP port and the player limit (defaulting to `42365` and `32`). The port you enter is also written into `GAME_PORT` in the generated `/etc/palworld-auto/config`, so `palworld-wake` listens on the same port. In a non-interactive run (e.g. from another script), a missing file just fails the install.

If you want to launch the server with parameters (port, player limit, multithreading) instead of a bare `./PalServer.sh`, you can also create `start.sh` in `PALWORLD_DIR` yourself and make it executable (`chmod +x`) — this is the same template the installer uses:

```bash
#!/usr/bin/env bash
exec ./PalServer.sh \
  -port=42365 \
  -players=32 \
  -useperfthreads \
  -NoAsyncLoadingThread \
  -UseMultithreadForDS
```

`-port` must match `GAME_PORT` in `/etc/palworld-auto/config`, otherwise `palworld-wake` listens on the wrong port. `exec` replaces the bash process with `PalServer.sh` so `systemd` manages the actual game server process, not an extra wrapper.

Officially documented command-line arguments: <https://docs.palworldgame.com/settings-and-operation/arguments/>

| Flag | Purpose |
|---|---|
| `-port=8211` | Server UDP port |
| `-players=32` | Maximum players |
| `-useperfthreads` `-NoAsyncLoadingThread` `-UseMultithreadForDS` | The official recommended multithreading combo (used together) |
| `-NumberOfWorkerThreadsServer=N` | Number of worker threads |
| `-publiclobby` | Set up the server as a community server |
| `-publicip=x.x.x.x`, `-publicport=xxxx` | Explicitly set the public IP/port |
| `-logformat=text\|json` | Log format |

`ServerName`, `ServerPassword`, and `AdminPassword` are **not documented as command-line arguments** — set them only inside `OptionSettings=(...)` in `PalWorldSettings.ini` (see below), not as `start.sh` flags.

## Configuring the Palworld REST API

Open:

```bash
nano /home/server/palworld/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini
```

If the file does not exist yet, create it from the template (editing `DefaultPalWorldSettings.ini` has no effect):

```bash
cp /home/server/palworld/DefaultPalWorldSettings.ini \
   /home/server/palworld/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini
```

The whole file is a single line shaped like this (values shortened for the example — full parameter list linked below):

```ini
[/Script/Pal.PalGameWorldSettings]
OptionSettings=(Difficulty=None,DayTimeSpeedRate=1.000000,ExpRate=1.000000,ServerName="My Palworld Server",ServerDescription="",AdminPassword="STRONG_PASSWORD",ServerPassword="",PublicPort=8211,PublicIP="",RCONEnabled=False,RCONPort=25575,RESTAPIEnabled=True,RESTAPIPort=8212,ServerPlayerMaxNum=32)
```

Inside `OptionSettings=(...)` you need at least (no line breaks):

```ini
AdminPassword="STRONG_PASSWORD"
RESTAPIEnabled=True
RESTAPIPort=8212
```

Do not expose the REST API port `8212` to the internet. The scripts only reach it through `127.0.0.1`.

Full parameter list and descriptions: <https://docs.palworldgame.com/settings-and-operation/configuration/>

Official REST API documentation:

- [Palworld REST API](https://docs.palworldgame.com/api/rest-api/palwold-rest-api/)
- [Save API](https://docs.palworldgame.com/api/rest-api/save/)
- [Shutdown API](https://docs.palworldgame.com/api/rest-api/shutdown/)

### Quick config-editing commands

Stop the server before editing:

```bash
sudo systemctl stop palworld.service
```

Set the path once:

```bash
CONFIG="/home/server/palworld/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini"
```

Change the admin password:

```bash
sudo sed -i -E \
  's/AdminPassword="[^"]*"/AdminPassword="NEW_PASSWORD"/' \
  "$CONFIG"
```

Enable the REST API and set its port:

```bash
sudo sed -i -E 's/RESTAPIEnabled=(True|False)/RESTAPIEnabled=True/' "$CONFIG"
sudo sed -i -E 's/RESTAPIPort=[0-9]+/RESTAPIPort=8212/' "$CONFIG"
```

Check current values without revealing the password:

```bash
sudo grep -oE \
  'AdminPassword="[^"]*"|RESTAPIEnabled=(True|False)|RESTAPIPort=[0-9]+' \
  "$CONFIG" |
sed -E 's/AdminPassword="[^"]*"/AdminPassword="***"/'
```

If you changed the password or the REST API port, update the automation side too:

```bash
sudo sh -c 'umask 077; printf "%s\n" "NEW_PASSWORD" > /etc/palworld-auto/admin-password'
sudo nano /etc/palworld-auto/config   # REST_PORT, if you changed RESTAPIPort
sudo systemctl restart palworld-idle.service
```

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

## Managing the services

The installer already enables `palworld-wake.service` and, if a password was set, `palworld-idle.service`. Below are combined commands to bring everything up or down at once, followed by per-unit management.

If commands in this section fail with something like `Unit file palworld-idle.service does not exist`, `sudo ./install.sh ...` hasn't run successfully yet — the unit files don't appear in `/etc/systemd/system` just because you cloned the repo. See [Installation](#installation) and [Common problems](#unit-file-palworld-idleservice-does-not-exist).

### Start everything

If the automation is already installed (see [Installation](#installation)) but the services aren't running:

```bash
sudo systemctl enable --now palworld-wake.service
sudo systemctl enable --now palworld-idle.service   # only if an admin password is set
```

You don't have to start the game server by hand — `palworld-wake.service` will start it on the first UDP packet. But you can start it right away too:

```bash
sudo systemctl start palworld.service
```

Check that everything is running:

```bash
systemctl status palworld-wake.service palworld-idle.service palworld.service
```

Expected: `palworld-wake` and `palworld-idle` are `active (running)`. `palworld` is `active (running)` if you started it by hand, or `inactive (dead)` until the first connection attempt (that's expected — see [Important limitation](#important-limitation)).

### Stop everything

Pause the automation without touching a running server:

```bash
sudo systemctl disable --now palworld-idle.service
sudo systemctl disable --now palworld-wake.service
```

Also stop the game server itself:

```bash
sudo systemctl stop palworld.service
```

After this, neither idle shutdown nor wake-on-UDP will work until you re-enable the services (see [Start everything](#start-everything) above).

### Game server (`palworld.service`)

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

### Idle shutdown (`palworld-idle.service`)

```bash
sudo systemctl enable --now palworld-idle.service   # enable at boot and start now
sudo systemctl restart palworld-idle.service        # apply a config change
sudo systemctl disable --now palworld-idle.service  # stop and remove from boot
systemctl status palworld-idle.service
```

### Wake-on-UDP (`palworld-wake.service`)

```bash
sudo systemctl enable --now palworld-wake.service
sudo systemctl restart palworld-wake.service
sudo systemctl disable --now palworld-wake.service
systemctl status palworld-wake.service
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

## Importing a local (co-op) save onto the dedicated server

A local (co-op) Palworld save does not run on a dedicated server as-is — it needs converting:

<https://hub.tcno.co/games/palworld/converter/>

The tool runs entirely in the browser, without uploading files to a third-party server. Upload your local save folder (in particular `Level.sav` and the player save folder) and download a ZIP with the converted files.

Where to place the result on the server:

1. Stop the server:

   ```bash
   sudo systemctl stop palworld.service
   ```

2. Find the current world's folder — a subdirectory with a long hex ID inside `SaveGames`:

   ```bash
   find /home/server/palworld/Pal/Saved/SaveGames -mindepth 2 -maxdepth 2 -type d
   ```

   If the server has never been started, start it once and stop it — this creates `Pal/Saved/SaveGames/0/<WORLD_ID>/` with a template set of files (`Level.sav`, `LevelMeta.sav`, `WorldOption.sav`, `Players/`).

3. Back up before overwriting:

   ```bash
   sudo cp -a /home/server/palworld/Pal/Saved/SaveGames \
             /home/server/palworld/Pal/Saved/SaveGames.bak
   ```

4. Extract the converter's ZIP into that world folder, replacing the existing files (`Level.sav`, player files, etc.), as instructed on the converter page.

5. Restore ownership to the user Palworld runs as:

   ```bash
   sudo chown -R server:server /home/server/palworld/Pal/Saved/SaveGames
   ```

6. Start the server and check the logs:

   ```bash
   sudo systemctl start palworld.service
   sudo journalctl -fu palworld.service
   ```

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

### `Unit file palworld-idle.service does not exist`

`systemctl enable/start/status` can't find the unit. This means the automation hasn't actually been installed into `/etc/systemd/system` — the `systemd/*.service` files in the cloned repo do nothing on their own; the installer has to copy them there.

Check whether the units are actually installed:

```bash
systemctl list-unit-files | grep palworld
```

If that's empty, run the installer from the repo root (not from the `systemd/` subdirectory):

```bash
cd ~/palworld-auto-sleep-wake
sudo ./install.sh --user server --palworld-dir /home/server/palworld
```

Read its output carefully — if the installer failed (missing dependencies, a user or directory that doesn't exist, etc.), the units won't be installed. Then retry [Start everything](#start-everything).

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
