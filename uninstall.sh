#!/usr/bin/env bash

set -Eeuo pipefail

PURGE=false

usage()
{
    cat <<'EOF'
Usage:
  sudo ./uninstall.sh [--purge]

Options:
  --purge     Also remove /etc/palworld-auto
  -h, --help  Show this help
EOF
}

while (($#)); do
    case "$1" in
        --purge)
            PURGE=true
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
    echo "Run this script as root" >&2
    exit 1
fi

systemctl disable --now palworld-idle.service >/dev/null 2>&1 || true
systemctl disable --now palworld-wake.service >/dev/null 2>&1 || true
systemctl disable --now palworld.service >/dev/null 2>&1 || true

rm -f /etc/systemd/system/palworld.service
rm -f /etc/systemd/system/palworld-idle.service
rm -f /etc/systemd/system/palworld-wake.service
rm -rf /usr/local/lib/palworld-auto

if [[ "$PURGE" == true ]]; then
    rm -rf /etc/palworld-auto
fi

systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1 || true

echo "Palworld auto sleep/wake removed."
if [[ "$PURGE" != true ]]; then
    echo "Configuration preserved in /etc/palworld-auto"
fi
echo "Palworld game files and saves were not modified."
