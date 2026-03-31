# lib/setup.sh — VPS setup: Docker, firewall, security hardening

# ─── Setup VPS ─────────────────────────────────────────────
# Usage: cp_setup <env>
cp_setup() {
    local env="$1"

    config_load_env "$env"

    lib_log_header_starting "setup ${env} (${CP_HOST})"

    _cp_ssh_opts
    local registry_port="${CP_REGISTRY_PORT:-5000}"

    # ── 1. Install Docker CE + Compose plugin ──
    lib_log_info "[1/10] Installing Docker..."
    ssh "${CP_SSH_OPTS[@]}" "${CP_USER}@${CP_HOST}" 'if ! command -v docker &> /dev/null; then
        curl -fsSL https://get.docker.com | sh
    else
        echo "Docker already installed"
    fi' || { lib_log_error "Failed to install Docker"; return 6; }
    lib_log_success "Docker ready"

    # ── 2. Configure Docker daemon (log rotation) ──
    lib_log_info "[2/10] Configuring Docker log rotation..."
    ssh "${CP_SSH_OPTS[@]}" "${CP_USER}@${CP_HOST}" 'mkdir -p /etc/docker && cat > /etc/docker/daemon.json << DAEMON_EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
DAEMON_EOF
systemctl restart docker' || { lib_log_error "Failed to configure Docker daemon"; return 6; }
    lib_log_success "Docker log rotation configured"

    # ── 3. Configure UFW ──
    lib_log_info "[3/10] Configuring firewall (UFW)..."
    ssh "${CP_SSH_OPTS[@]}" "${CP_USER}@${CP_HOST}" 'apt-get update -qq && apt-get install -y -qq ufw > /dev/null && \
        ufw default deny incoming && \
        ufw default allow outgoing && \
        ufw allow 22/tcp && \
        ufw allow 80/tcp && \
        ufw allow 443/tcp && \
        ufw --force enable' || { lib_log_error "Failed to configure UFW"; return 6; }
    lib_log_success "UFW configured (22, 80, 443)"

    # ── 4. Install + configure fail2ban ──
    lib_log_info "[4/10] Installing fail2ban..."
    ssh "${CP_SSH_OPTS[@]}" "${CP_USER}@${CP_HOST}" 'apt-get install -y -qq fail2ban > /dev/null && \
        cat > /etc/fail2ban/jail.local << F2B_EOF
[sshd]
enabled = true
port = ssh
maxretry = 5
bantime = 3600
findtime = 600
F2B_EOF
systemctl enable fail2ban && systemctl restart fail2ban' || { lib_log_error "Failed to configure fail2ban"; return 6; }
    lib_log_success "fail2ban configured (5 retries, 1hr ban)"

    # ── 5. Configure swap ──
    lib_log_info "[5/10] Configuring swap..."
    ssh "${CP_SSH_OPTS[@]}" "${CP_USER}@${CP_HOST}" 'if [ ! -f /swapfile ]; then
        fallocate -l 4G /swapfile && \
        chmod 600 /swapfile && \
        mkswap /swapfile && \
        swapon /swapfile && \
        echo "/swapfile swap swap defaults 0 0" >> /etc/fstab && \
        echo "Swap created (4GB)"
    else
        echo "Swap already exists"
    fi' || { lib_log_error "Failed to configure swap"; return 6; }
    lib_log_success "Swap ready (4GB)"

    # ── 6. Enable unattended-upgrades ──
    lib_log_info "[6/10] Enabling unattended-upgrades..."
    ssh "${CP_SSH_OPTS[@]}" "${CP_USER}@${CP_HOST}" 'apt-get install -y -qq unattended-upgrades > /dev/null && \
        dpkg-reconfigure -f noninteractive unattended-upgrades' || { lib_log_error "Failed to enable unattended-upgrades"; return 6; }
    lib_log_success "Unattended-upgrades enabled"

    # ── 7. Harden SSH ──
    lib_log_info "[7/10] Hardening SSH..."
    ssh "${CP_SSH_OPTS[@]}" "${CP_USER}@${CP_HOST}" 'sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config && \
        (systemctl restart sshd 2>/dev/null || systemctl restart ssh)' || { lib_log_error "Failed to harden SSH"; return 6; }
    lib_log_success "SSH hardened (password auth disabled)"

    # ── 8. Start local Docker registry ──
    lib_log_info "[8/10] Starting local Docker registry (port ${registry_port})..."
    ssh "${CP_SSH_OPTS[@]}" "${CP_USER}@${CP_HOST}" "if docker ps --format '{{.Names}}' | grep -q '^registry\$'; then
        echo 'Registry already running'
    else
        docker rm -f registry 2>/dev/null || true
        docker run -d --restart unless-stopped --name registry \
            -p 127.0.0.1:${registry_port}:5000 \
            -v registry_data:/var/lib/registry \
            registry:2
    fi" || { lib_log_error "Failed to start registry"; return 6; }
    lib_log_success "Registry ready (127.0.0.1:${registry_port})"

    # ── 9. Create proxy network ──
    lib_log_info "[9/10] Creating proxy network..."
    ssh "${CP_SSH_OPTS[@]}" "${CP_USER}@${CP_HOST}" \
        'docker network ls --format "{{.Name}}" | grep -q "^proxy$" || docker network create proxy' \
        || { lib_log_error "Failed to create proxy network"; return 6; }
    lib_log_success "Proxy network ready"

    # ── 10. Create directories ──
    lib_log_info "[10/10] Creating directories..."
    ssh "${CP_SSH_OPTS[@]}" "${CP_USER}@${CP_HOST}" 'mkdir -p ~/deployment ~/.compose-publisher' || { lib_log_error "Failed to create directories"; return 6; }
    lib_log_success "Directories created"

    lib_log_header_done "setup ${env}"
}
