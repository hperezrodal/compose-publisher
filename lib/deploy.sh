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

# ─── Lifecycle finalizer ───────────────────────────────────
# Non-blocking notifier + retained-clone cleanup. Never changes the
# exit code (the caller returns/propagates it).
_cp_finalize() {
    local status="$1" stage="$2" code="$3" start_ts="$4"
    local dur=$(( $(date +%s) - start_ts ))
    cp_notify "$status" "$stage" "$code" "$dur" || true
    _cp_cleanup_clone || true
}

# ─── Full deploy pipeline for one component ────────────────
# Usage: cp_pipeline_deploy <component> <env>
# Order: pre_deploy → build → transfer → up → wait-healthy → post_deploy
# Exit codes: 8 pre-abort, 9 post-fail, 10 health-timeout; 2/3/4/5 from
# build/transfer/deploy. The notifier finalizer fires on every path.
# Backward compatible: no hooks/notify ⇒ identical to the old
# build→transfer→deploy sequence (plus the unchanged clone cleanup).
cp_pipeline_deploy() {
    local component="$1" env="$2" rc=0
    local start_ts
    start_ts=$(date +%s)

    # Load config early so hooks/notify are known before build (and so
    # build.sh can decide whether to retain the clone).
    config_load_env "$env"
    config_load_component "$component"

    # Strategy branch (D28): blue-green delegates; recreate = Phase A
    # path below, byte-for-byte unchanged.
    if [[ "${CP_STRATEGY:-recreate}" == "blue-green" ]]; then
        cp_pipeline_deploy_bg "$component" "$env" "$start_ts"
        return $?
    fi

    # 1. pre_deploy — before any mutation; hard abort on failure (D13)
    rc=0; cp_hook_run pre || rc=$?
    if (( rc != 0 )); then
        lib_log_error "pre_deploy failed — aborting deploy (nothing built/changed)"
        _cp_finalize aborted pre 8 "$start_ts"
        return 8
    fi

    # 2. build → transfer → up
    rc=0; cp_build "$component" "$env" || rc=$?
    if (( rc != 0 )); then _cp_finalize failed build "$rc" "$start_ts"; return "$rc"; fi
    rc=0; cp_transfer || rc=$?
    if (( rc != 0 )); then _cp_finalize failed transfer "$rc" "$start_ts"; return "$rc"; fi
    rc=0; cp_deploy "$component" "$env" || rc=$?
    if (( rc != 0 )); then _cp_finalize failed up "$rc" "$start_ts"; return "$rc"; fi

    # 3. wait-for-healthy (D4)
    rc=0; cp_wait_healthy || rc=$?
    if (( rc != 0 )); then _cp_finalize failed health 10 "$start_ts"; return 10; fi

    # 4. post_deploy — distinct exit code 9 (D5); no rollback here
    rc=0; cp_hook_run post || rc=$?
    if (( rc != 0 )); then
        lib_log_error "post_deploy failed (deploy applied, gate failed)"
        _cp_finalize failed post 9 "$start_ts"
        return 9
    fi

    _cp_finalize success "" 0 "$start_ts"
    return 0
}

# ─── Blue/green pipeline (Phase B) ─────────────────────────
# Guarantee: a bad new version never takes traffic; the old color
# keeps serving until dev fixes. Exit 11 = green failed validation,
# NOT flipped, blue still serving (zero user impact). Config already
# loaded by cp_pipeline_deploy.
cp_pipeline_deploy_bg() {
    local component="$1" env="$2" start_ts="$3" rc=0

    # 1. pre_deploy (D13) — before any mutation
    rc=0; cp_hook_run pre || rc=$?
    if (( rc != 0 )); then
        lib_log_error "pre_deploy failed — aborting (nothing changed)"
        _cp_finalize aborted pre 8 "$start_ts"; return 8
    fi

    # 2. resolve colors (D21/D26)
    cp_bg_resolve

    # 3. build + transfer the image (shared by both colors)
    rc=0; cp_build "$component" "$env" || rc=$?
    if (( rc != 0 )); then _cp_finalize failed build "$rc" "$start_ts"; return "$rc"; fi
    rc=0; cp_transfer || rc=$?
    if (( rc != 0 )); then _cp_finalize failed transfer "$rc" "$start_ts"; return "$rc"; fi

    # 4. bring up the IDLE/target color (no public router yet)
    rc=0; cp_bg_up_color "$CP_BG_TARGET" || rc=$?
    if (( rc != 0 )); then _cp_finalize failed bg-up "$rc" "$start_ts"; return "$rc"; fi

    # 5. validate the target color: wait-healthy + smoke, with ZERO
    #    public traffic. Any failure ⇒ DO NOT FLIP; old color keeps
    #    serving; leave target up for inspection (D23); exit 11.
    rc=0; ( CP_COMPOSE_SERVICE="${CP_COMPOSE_SERVICE}-${CP_BG_TARGET}"; cp_wait_healthy ) || rc=$?
    if (( rc != 0 )); then
        lib_log_error "blue/green: ${CP_BG_TARGET} not healthy — NOT flipping; old color still serving"
        _cp_finalize failed bg-health 11 "$start_ts"; return 11
    fi
    rc=0; cp_bg_smoke_idle || rc=$?
    if (( rc != 0 )); then
        lib_log_error "blue/green: smoke on ${CP_BG_TARGET} failed — NOT flipping; old color still serving"
        _cp_finalize failed bg-smoke 11 "$start_ts"; return 11
    fi

    # 6. flip (D22): atomic dynamic-file swap. Old color stays up.
    rc=0; cp_bg_flip "$CP_BG_TARGET" || rc=$?
    if (( rc != 0 )); then
        lib_log_error "blue/green: flip failed — old color still serving (no change)"
        _cp_finalize failed flip 11 "$start_ts"; return 11
    fi

    # 7. soak + retire old color; on bootstrap retire the pre-existing
    #    recreate container so its stale router stops conflicting (D26).
    if (( CP_BG_BOOTSTRAP == 0 )); then
        cp_bg_soak
        cp_bg_retire "$CP_BG_ACTIVE"
    else
        cp_bg_retire_recreate
    fi

    _cp_finalize success "flip:${CP_BG_TARGET}" 0 "$start_ts"
    return 0
}

# ─── Deploy all components ─────────────────────────────────
# Usage: cp_deploy_all <env>
# Runs the full lifecycle per component; stops on the first failure and
# propagates that component's exit code (SPEC §6).
cp_deploy_all() {
    local env="$1"

    lib_log_header_starting "deploy --all (env: ${env})"

    local components rc
    components=$(config_list_components)

    while IFS= read -r component <&3; do
        [[ -z "$component" ]] && continue
        lib_log_info "Deploying component: ${component}"
        rc=0; cp_pipeline_deploy "$component" "$env" || rc=$?
        if (( rc != 0 )); then
            lib_log_error "deploy --all stopped at '${component}' (exit ${rc})"
            return "$rc"
        fi
    done 3<<< "$components"

    lib_log_header_done "deploy --all"
}
