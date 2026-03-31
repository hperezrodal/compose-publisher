# lib/env.sh — .env file management + SSH access

# ─── Push .env to VPS ──────────────────────────────────────
# Usage: cp_env_push <env>
# F-008: env commands use CP_DEPLOY_PATH as-is (no stack appending).
# The user should configure deploy_path to match where deploy puts files.
# V2 will add stack-awareness to env commands.
cp_env_push() {
    local env="$1"

    config_load_env "$env"

    lib_log_header_starting "env push (env: ${env})"

    if [[ -z "$CP_ENV_FILE" ]]; then
        lib_log_error "No env_file configured for environment '${env}'"
        return 7
    fi

    if [[ ! -f "$CP_ENV_FILE" ]]; then
        lib_log_error "Env file not found: ${CP_ENV_FILE}"
        return 7
    fi

    # F-006: Use array for SSH opts
    _cp_ssh_opts
    local remote_dir="${CP_DEPLOY_PATH}"

    ssh "${CP_SSH_OPTS[@]}" "${CP_USER}@${CP_HOST}" "mkdir -p ${remote_dir}"
    # F-005: Use || for proper exit code
    scp "${CP_SSH_OPTS[@]}" "$CP_ENV_FILE" "${CP_USER}@${CP_HOST}:${remote_dir}/.env" || {
        lib_log_error "Failed to push env file to ${CP_HOST}"
        return 7
    }

    lib_log_success "Pushed ${CP_ENV_FILE} → ${CP_HOST}:${remote_dir}/.env"
    lib_log_header_done "env push"
}

# ─── Pull .env from VPS ───────────────────────────────────
# Usage: cp_env_pull <env>
cp_env_pull() {
    local env="$1"

    config_load_env "$env"

    lib_log_header_starting "env pull (env: ${env})"

    if [[ -z "$CP_ENV_FILE" ]]; then
        lib_log_error "No env_file configured for environment '${env}'"
        return 7
    fi

    # F-006: Use array for SSH opts
    _cp_ssh_opts
    local remote_dir="${CP_DEPLOY_PATH}"

    # Ensure local directory exists
    local local_dir
    local_dir=$(dirname "$CP_ENV_FILE")
    mkdir -p "$local_dir"

    # F-005: Use || for proper exit code
    scp "${CP_SSH_OPTS[@]}" "${CP_USER}@${CP_HOST}:${remote_dir}/.env" "$CP_ENV_FILE" || {
        lib_log_error "Failed to pull env file from ${CP_HOST}"
        return 7
    }

    lib_log_success "Pulled ${CP_HOST}:${remote_dir}/.env → ${CP_ENV_FILE}"
    lib_log_header_done "env pull"
}

# ─── SSH into VPS ──────────────────────────────────────────
# Usage: cp_ssh <env>
# F-012: Intentionally NOT using _cp_ssh_opts / ConnectTimeout.
# Interactive sessions should not have a connection timeout.
cp_ssh() {
    local env="$1"

    config_load_env "$env"

    lib_log_info "Connecting to ${CP_HOST} as ${CP_USER}..."
    exec ssh -o StrictHostKeyChecking=no -i "$CP_SSH_KEY" "${CP_USER}@${CP_HOST}"
}
