#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must be run as root (or with sudo)"
    exit 1
fi

rm -f /usr/local/bin/compose-publisher
rm -rf /usr/local/lib/compose-publisher

echo "compose-publisher uninstalled."
