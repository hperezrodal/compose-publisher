# lib/transfer.sh — Transfer Docker images to VPS via local registry

# ─── Transfer image to VPS ─────────────────────────────────
# Uses: SSH tunnel + docker push to VPS-local registry (localhost:5000)
# First push sends all layers; subsequent pushes only send changed layers.
# Requires: CP_IMAGE, CP_TAG, CP_HOST, CP_USER, CP_SSH_KEY (from build + config)
cp_transfer() {
    lib_validate_params \
        "CP_IMAGE" "${CP_IMAGE:-}" \
        "CP_TAG" "${CP_TAG:-}" \
        "CP_HOST" "${CP_HOST:-}"

    local registry_port="${CP_REGISTRY_PORT:-5000}"
    local registry="localhost:${registry_port}"

    lib_log_header_starting "transfer ${CP_IMAGE}:${CP_TAG} → ${CP_HOST}"

    _cp_ssh_opts

    # 1. Tag for registry
    docker tag "${CP_IMAGE}:${CP_TAG}" "${registry}/${CP_IMAGE}:${CP_TAG}" || {
        lib_log_error "Failed to tag ${CP_IMAGE}:${CP_TAG}"
        return 4
    }
    docker tag "${CP_IMAGE}:latest" "${registry}/${CP_IMAGE}:latest" || {
        lib_log_error "Failed to tag ${CP_IMAGE}:latest"
        return 4
    }

    # 2. Open SSH tunnel to VPS registry
    lib_log_info "Opening tunnel to ${CP_HOST}:${registry_port}..."
    ssh "${CP_SSH_OPTS[@]}" \
        -L "${registry_port}:localhost:${registry_port}" \
        -f -N -o ExitOnForwardFailure=yes \
        "${CP_USER}@${CP_HOST}" < /dev/null || {
        lib_log_error "Failed to open SSH tunnel to ${CP_HOST}"
        return 4
    }

    local tunnel_pid
    tunnel_pid=$(lsof -ti:"${registry_port}" -sTCP:LISTEN 2>/dev/null)

    # 3. Push (only changed layers are transferred)
    lib_log_info "Pushing ${CP_IMAGE}:${CP_TAG}..."
    docker push "${registry}/${CP_IMAGE}:${CP_TAG}" || {
        lib_log_error "Failed to push ${CP_IMAGE}:${CP_TAG}"
        kill "$tunnel_pid" 2>/dev/null
        return 4
    }

    lib_log_info "Pushing ${CP_IMAGE}:latest..."
    docker push "${registry}/${CP_IMAGE}:latest" || {
        lib_log_error "Failed to push ${CP_IMAGE}:latest"
        kill "$tunnel_pid" 2>/dev/null
        return 4
    }

    # 4. Close tunnel
    kill "$tunnel_pid" 2>/dev/null

    lib_log_success "Transferred ${CP_IMAGE}:${CP_TAG} to ${CP_HOST}"
    lib_log_header_done "transfer"
}
