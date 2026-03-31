#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/usr/local/lib/compose-publisher"
BIN_DIR="/usr/local/bin"

echo "compose-publisher installer"
echo "==========================="

# Check root
if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must be run as root (or with sudo)"
    exit 1
fi

# F-019: Check bash-library in system, root home, and sudo user home
SUDO_USER_HOME=""
if [[ -n "${SUDO_USER:-}" ]]; then
    SUDO_USER_HOME=$(eval echo "~${SUDO_USER}")
fi
if [[ ! -f "/usr/local/lib/bash-library/lib-loader.sh" \
   && ! -f "${HOME}/.local/lib/bash-library/lib-loader.sh" \
   && ( -z "$SUDO_USER_HOME" || ! -f "${SUDO_USER_HOME}/.local/lib/bash-library/lib-loader.sh" ) ]]; then
    echo ""
    echo "bash-library not found. Installing..."
    echo ""
    if command -v git &> /dev/null; then
        git clone https://github.com/hperezrodal/bash-library.git /tmp/bash-library-install
        cd /tmp/bash-library-install && bash install.sh
        rm -rf /tmp/bash-library-install
    else
        echo "ERROR: git is required to install bash-library"
        echo "Install git first, or install bash-library manually:"
        echo "  https://github.com/hperezrodal/bash-library"
        exit 1
    fi
fi

# Check yq
if ! command -v yq &> /dev/null; then
    echo ""
    echo "yq not found. Installing..."
    local_arch=$(uname -m)
    case "$local_arch" in
        x86_64)  local_arch="amd64" ;;
        aarch64) local_arch="arm64" ;;
    esac
    local_os=$(uname -s | tr '[:upper:]' '[:lower:]')
    # F-022: Use curl instead of wget (more commonly available)
    curl -fsSL -o "${BIN_DIR}/yq" "https://github.com/mikefarah/yq/releases/latest/download/yq_${local_os}_${local_arch}"
    chmod +x "${BIN_DIR}/yq"
    echo "yq installed"
fi

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Install compose-publisher
echo ""
echo "Installing compose-publisher..."

mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR"/lib/*.sh "$INSTALL_DIR/"
cp "$SCRIPT_DIR/bin/compose-publisher" "$BIN_DIR/compose-publisher"
chmod +x "$BIN_DIR/compose-publisher"
chmod 644 "$INSTALL_DIR"/*.sh

echo ""
echo "compose-publisher installed successfully!"
echo "  CLI: ${BIN_DIR}/compose-publisher"
echo "  Lib: ${INSTALL_DIR}/"
echo ""
echo "Run 'compose-publisher --help' to get started."
