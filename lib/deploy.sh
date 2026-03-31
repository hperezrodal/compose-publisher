# lib/deploy.sh — Deploy to VPS with targeted service recreation

# ─── Deploy a single component ─────────────────────────────
# Usage: cp_deploy <component> <env>
cp_deploy() {
    local component="$1"
    local env="$2"

    config_load_env "$env"
    config_load_component "$component"

    lib_log_header_starting "deploy ${component} → ${CP_HOST} (env: ${env})"

    # F-006: Use array for SSH opts
    _cp_ssh_opts

    # F-007: Append stack to deploy path for directory separation
    local remote_dir="${CP_DEPLOY_PATH}/${CP_STACK}"

    # 1. Ensure remote directory exists
    ssh "${CP_SSH_OPTS[@]}" "${CP_USER}@${CP_HOST}" "mkdir -p ${remote_dir}"

    # 2. Copy .env file
    if [[ -n "$CP_ENV_FILE" && -f "$CP_ENV_FILE" ]]; then
        scp "${CP_SSH_OPTS[@]}" "$CP_ENV_FILE" "${CP_USER}@${CP_HOST}:${remote_dir}/.env"
        lib_log_info "Copied ${CP_ENV_FILE} → ${remote_dir}/.env"
    fi

    # 3. Copy compose files
    local compose_flags=""
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        if [[ ! -f "$file" ]]; then
            lib_log_error "Compose file not found: ${file}"
            return 5
        fi
        scp "${CP_SSH_OPTS[@]}" "$file" "${CP_USER}@${CP_HOST}:${remote_dir}/$(basename "$file")"
        compose_flags+=" -f $(basename "$file")"
        lib_log_info "Copied ${file} → ${remote_dir}/"
    done <<< "$CP_COMPOSE_FILES"

    # 4. Pull + deploy (targeted) — F-004: use || for proper exit code
    lib_log_info "Deploying ${CP_COMPOSE_SERVICE}..."
    ssh "${CP_SSH_OPTS[@]}" "${CP_USER}@${CP_HOST}" \
        "cd ${remote_dir} && docker compose ${compose_flags} pull ${CP_COMPOSE_SERVICE} && docker compose ${compose_flags} up -d --no-deps --force-recreate ${CP_COMPOSE_SERVICE}" || {
        lib_log_error "Deploy failed for ${CP_COMPOSE_SERVICE} on ${CP_HOST}"
        return 5
    }

    # 5. Record deploy history — F-015/F-025: use printf for safe escaping
    local timestamp
    timestamp=$(lib_datetime_now)
    local history_line
    history_line=$(printf '%s %s %s %s' "$timestamp" "$component" "${CP_TAG:-latest}" "$env")
    ssh "${CP_SSH_OPTS[@]}" "${CP_USER}@${CP_HOST}" \
        "mkdir -p ~/.compose-publisher && printf '%s\n' '${history_line}' >> ~/.compose-publisher/deploy-history.log"

    lib_log_success "Deployed ${CP_COMPOSE_SERVICE} (${CP_TAG:-latest}) to ${CP_HOST}"
    lib_log_header_done "deploy ${component}"
}

# ─── Deploy all components ─────────────────────────────────
# Usage: cp_deploy_all <env>
# F-014: Note — stops on first error due to set -e. This is intentional for V1.
# Future: wrap each component in subshell for error isolation.
cp_deploy_all() {
    local env="$1"

    lib_log_header_starting "deploy --all (env: ${env})"

    local components
    components=$(config_list_components)

    while IFS= read -r component <&3; do
        [[ -z "$component" ]] && continue
        lib_log_info "Deploying component: ${component}"
        cp_build "$component" "$env"
        cp_transfer
        cp_deploy "$component" "$env"
    done 3<<< "$components"

    lib_log_header_done "deploy --all"
}
