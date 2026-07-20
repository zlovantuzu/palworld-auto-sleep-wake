#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/usr/local/lib/palworld-auto"
CONFIG_DIR="/etc/palworld-auto"
CONFIG_FILE="${CONFIG_DIR}/config"
PASSWORD_FILE="${CONFIG_DIR}/admin-password"
SYSTEMD_DIR="/etc/systemd/system"

PALWORLD_USER="server"
PALWORLD_GROUP=""
PALWORLD_DIR="/home/server/palworld"
INSTALL_DEPS=true

usage()
{
    cat <<'EOF'
Usage:
  sudo ./install.sh [options]

Options:
  --user USER              Linux user that runs Palworld (default: server)
  --group GROUP            Linux group (default: user's primary group)
  --palworld-dir PATH      Palworld directory
  --no-install-deps        Do not install missing apt dependencies
  -h, --help               Show this help
EOF
}

while (($#)); do
    case "$1" in
        --user)
            PALWORLD_USER="${2:?Missing value for --user}"
            shift 2
            ;;
        --group)
            PALWORLD_GROUP="${2:?Missing value for --group}"
            shift 2
            ;;
        --palworld-dir)
            PALWORLD_DIR="${2:?Missing value for --palworld-dir}"
            shift 2
            ;;
        --no-install-deps)
            INSTALL_DEPS=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if (( EUID != 0 )); then
    echo "Run this installer as root: sudo ./install.sh ..." >&2
    exit 1
fi

if ! id "$PALWORLD_USER" >/dev/null 2>&1; then
    echo "Linux user does not exist: $PALWORLD_USER" >&2
    exit 1
fi

if [[ -z "$PALWORLD_GROUP" ]]; then
    PALWORLD_GROUP="$(id -gn "$PALWORLD_USER")"
fi

if ! getent group "$PALWORLD_GROUP" >/dev/null 2>&1; then
    echo "Linux group does not exist: $PALWORLD_GROUP" >&2
    exit 1
fi

if [[ ! "$PALWORLD_USER" =~ ^[a-zA-Z0-9_.-]+$ ]] ||
   [[ ! "$PALWORLD_GROUP" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo "Unsupported user or group name" >&2
    exit 1
fi

if [[ ! -d "$PALWORLD_DIR" ]]; then
    echo "Palworld directory does not exist: $PALWORLD_DIR" >&2
    exit 1
fi

if [[ ! -f "$PALWORLD_DIR/start.sh" ]]; then
    echo "start.sh was not found in: $PALWORLD_DIR" >&2
    exit 1
fi

chmod +x "$PALWORLD_DIR/start.sh"

missing=()
for command_name in curl jq tcpdump systemctl; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
done

if ((${#missing[@]})); then
    if [[ "$INSTALL_DEPS" == true ]] && command -v apt-get >/dev/null 2>&1; then
        echo "Installing dependencies: ${missing[*]}"
        apt-get update
        apt-get install -y curl jq tcpdump
    else
        echo "Missing required commands: ${missing[*]}" >&2
        exit 1
    fi
fi

install -d -m 0755 "$INSTALL_DIR"
install -d -m 0700 "$CONFIG_DIR"

install -m 0755 "$PROJECT_DIR/scripts/palworld-run" \
    "$INSTALL_DIR/palworld-run"
install -m 0755 "$PROJECT_DIR/scripts/palworld-idle-watch" \
    "$INSTALL_DIR/palworld-idle-watch"
install -m 0755 "$PROJECT_DIR/scripts/palworld-wake" \
    "$INSTALL_DIR/palworld-wake"

if [[ ! -e "$CONFIG_FILE" ]]; then
    install -m 0600 "$PROJECT_DIR/config/palworld-auto.conf.example" \
        "$CONFIG_FILE"

    escaped_dir="${PALWORLD_DIR//\\/\\\\}"
    escaped_dir="${escaped_dir//&/\\&}"
    escaped_dir="${escaped_dir//|/\\|}"

    sed -i \
        "s|^PALWORLD_DIR=.*|PALWORLD_DIR=\"${escaped_dir}\"|" \
        "$CONFIG_FILE"

    echo "Created configuration: $CONFIG_FILE"
else
    echo "Keeping existing configuration: $CONFIG_FILE"
fi

if [[ ! -e "$PASSWORD_FILE" ]]; then
    install -m 0600 /dev/null "$PASSWORD_FILE"
fi

if [[ -t 0 ]] && [[ ! -s "$PASSWORD_FILE" ]]; then
    printf 'Palworld AdminPassword (hidden, Enter to skip): '
    IFS= read -r -s admin_password
    printf '\n'

    if [[ -n "$admin_password" ]]; then
        printf '%s\n' "$admin_password" >"$PASSWORD_FILE"
        chmod 0600 "$PASSWORD_FILE"
        unset admin_password
        echo "Admin password saved to $PASSWORD_FILE"
    fi
fi

sed \
    -e "s/@PALWORLD_USER@/${PALWORLD_USER}/g" \
    -e "s/@PALWORLD_GROUP@/${PALWORLD_GROUP}/g" \
    "$PROJECT_DIR/systemd/palworld.service.in" \
    >"$SYSTEMD_DIR/palworld.service"

install -m 0644 "$PROJECT_DIR/systemd/palworld-idle.service" \
    "$SYSTEMD_DIR/palworld-idle.service"
install -m 0644 "$PROJECT_DIR/systemd/palworld-wake.service" \
    "$SYSTEMD_DIR/palworld-wake.service"

systemctl daemon-reload

# Palworld itself must not start automatically at boot.
systemctl disable palworld.service >/dev/null 2>&1 || true

systemctl enable --now palworld-wake.service

if [[ -s "$PASSWORD_FILE" ]]; then
    systemctl enable --now palworld-idle.service
else
    systemctl enable palworld-idle.service
    echo
    echo "Admin password is empty. Set it with:"
    echo "  sudo sh -c 'umask 077; printf \"%s\\n\" \"YOUR_PASSWORD\" > $PASSWORD_FILE'"
    echo "Then start the idle watcher:"
    echo "  sudo systemctl start palworld-idle.service"
fi

cat <<EOF

Installation complete.

Configuration:
  $CONFIG_FILE

Admin password:
  $PASSWORD_FILE

Useful commands:
  sudo systemctl start palworld.service
  sudo systemctl stop palworld.service
  sudo journalctl -u palworld.service -u palworld-idle.service -u palworld-wake.service -f

Verify GAME_PORT, REST_PORT and IDLE_SECONDS before relying on automation.
EOF
