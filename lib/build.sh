# lib/build.sh — Build Docker images from git or local source
# F-009: BLOCKED — lib_docker_build_image doesn't support --target or custom context.
# Using docker build directly with proper array handling (F-016).

# ─── Build a component ────────────────────────────────────
# Usage: cp_build <component> <env>
# Exports: CP_IMAGE, CP_TAG (for transfer/deploy)
cp_build() {
    local component="$1"
    local env="$2"

    # F-017: Save working directory to restore after build
    local original_dir
    original_dir="$(pwd)"

    config_load_env "$env"
    config_load_component "$component"

    lib_log_header_starting "build ${component} (env: ${env})"

    local build_dir=""
    local source_type=""

    # ── Determine source type ──
    if [[ "$CP_SOURCE" == ./* || "$CP_SOURCE" == /* ]]; then
        source_type="local"
        build_dir="$CP_SOURCE"
        lib_log_info "Source: local (${build_dir})"
    else
        source_type="git"
        build_dir="/tmp/${component}-$(lib_datetime_now)"
        lib_log_info "Source: git (${CP_SOURCE})"
        lib_log_info "Branch: ${CP_BRANCH}"

        lib_git_clone_repo "$CP_SOURCE" "$build_dir" || {
            lib_log_error "Failed to clone ${CP_SOURCE}"
            cd "$original_dir"
            return 3
        }
        cd "$build_dir" || {
            lib_log_error "Failed to enter build dir"
            cd "$original_dir"
            return 3
        }
        lib_git_switch_branch "$CP_BRANCH" || {
            lib_log_error "Failed to switch to branch ${CP_BRANCH}"
            rm -rf "$build_dir"
            cd "$original_dir"
            return 3
        }
    fi

    # ── Resolve tag ──
    cd "$build_dir" || {
        lib_log_error "Failed to enter build dir"
        cd "$original_dir"
        return 3
    }
    local commit
    commit=$(lib_git_current_commit 2>/dev/null || echo "unknown")
    local tag="${CP_BRANCH}.${commit}"
    local image="${CP_COMPOSE_SERVICE}"

    lib_log_info "Image: ${image}:${tag}"

    # ── Build command array (F-016: arrays prevent word-splitting) ──
    local -a build_cmd=(docker build --platform "$CP_PLATFORM"
        -t "${image}:${tag}"
        -t "${image}:latest"
    )

    # Target flag
    if [[ -n "$CP_TARGET" ]]; then
        build_cmd+=(--target "$CP_TARGET")
        lib_log_info "Target: ${CP_TARGET}"
    fi

    # Build args (F-001: use envsubst instead of eval)
    local arg_keys
    arg_keys=$(_cp_yq ".components.${component}.args | keys | .[]" 2>/dev/null)
    if [[ -n "$arg_keys" ]]; then
        while IFS= read -r key; do
            local value
            value=$(_cp_yq ".components.${component}.args.${key}")
            value=$(echo "$value" | envsubst)
            build_cmd+=(--build-arg "${key}=${value}")
            lib_log_info "Build arg: ${key}"
        done <<< "$arg_keys"
    fi

    # Dockerfile and context
    build_cmd+=(-f "$CP_DOCKERFILE" "$CP_CONTEXT")

    # ── Docker build (F-002: use || pattern for proper error handling) ──
    lib_log_info "Building..."
    "${build_cmd[@]}" || {
        lib_log_error "Docker build failed for ${component}"
        if [[ "$source_type" == "git" ]]; then
            rm -rf "$build_dir"
        fi
        cd "$original_dir"
        return 2
    }

    # ── Cleanup git clone ──
    if [[ "$source_type" == "git" ]]; then
        cd /tmp || true
        rm -rf "$build_dir"
        lib_log_info "Cleaned up build directory"
    fi

    # ── Export for transfer/deploy ──
    export CP_IMAGE="${image}"
    export CP_TAG="${tag}"

    # F-017: Restore working directory
    cd "$original_dir"

    lib_log_success "Built ${image}:${tag}"
    lib_log_header_done "build ${component}"
}
