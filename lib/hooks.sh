# lib/hooks.sh — deploy lifecycle hooks, wait-for-healthy, outcome notifier
#
# Generic pre/post deploy hooks + a built-in wait-for-healthy step + an
# outcome-driven notifier (finalizer). See
# docs/features/lifecycle-hooks/SPEC.md. Everything here is a no-op when
# the consumer declares no hooks/notify (backward compatible).

# ─── Build the env (KEY=VALUE) passed to a hook/notifier ───
# Merged hook_env (env base + component override) + CP_* context.
# Echoes one KEY=VALUE per line. Extra context pairs are appended as
# args ($@).
_cp_hook_envkv() {
    config_hook_env_kv "${CP_ENV:-}" "${CP_COMPONENT:-}"
    printf '%s\n' \
        "CP_COMPONENT=${CP_COMPONENT:-}" \
        "CP_ENV=${CP_ENV:-}" \
        "CP_BRANCH=${CP_BRANCH:-}" \
        "CP_IMAGE=${CP_IMAGE:-}" \
        "CP_TAG=${CP_TAG:-}" \
        "CP_COMPOSE_SERVICE=${CP_COMPOSE_SERVICE:-}" \
        "CP_HOST=${CP_HOST:-}"
    [[ $# -gt 0 ]] && printf '%s\n' "$@"
    # Generic last-wins override (e.g. blue/green injects an internal
    # SMOKE_BASE_URL pointing at the idle color via an SSH tunnel).
    [[ -n "${CP_HOOK_EXTRA_ENV:-}" ]] && printf '%s\n' "${CP_HOOK_EXTRA_ENV}"
}

# ─── Does a where=runner hook need the build clone kept? ───
# Used by lib/build.sh to decide whether to defer clone cleanup (D2).
_cp_runner_hook_needs_clone() {
    [[ -n "${CP_PRE_RUN:-}"  && "${CP_PRE_WHERE:-runner}"  == "runner" ]] && return 0
    [[ -n "${CP_POST_RUN:-}" && "${CP_POST_WHERE:-runner}" == "runner" ]] && return 0
    return 1
}

# ─── Run a lifecycle hook ──────────────────────────────────
# Usage: cp_hook_run <pre|post>
# Returns: 0 ok / no hook; non-zero = hook failed (caller maps to exit
# code 8 for pre, 9 for post).
cp_hook_run() {
    local phase="$1"
    local run where timeout
    case "$phase" in
        pre)  run="${CP_PRE_RUN:-}";  where="${CP_PRE_WHERE:-runner}";  timeout="${CP_PRE_TIMEOUT:-300}" ;;
        post) run="${CP_POST_RUN:-}"; where="${CP_POST_WHERE:-runner}"; timeout="${CP_POST_TIMEOUT:-300}" ;;
        *) lib_log_error "cp_hook_run: bad phase '${phase}'"; return 2 ;;
    esac

    [[ -z "$run" ]] && return 0   # no hook declared → skip

    lib_log_info "Running ${phase}_deploy hook (where=${where}, timeout=${timeout}s): ${run}"

    # Collect env as an array of KEY=VALUE
    local -a envv=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && envv+=("$line")
    done < <(_cp_hook_envkv "CP_HOOK_PHASE=${phase}")

    if [[ "$where" == "host" ]]; then
        # Run on the environment host via ssh. The script itself decides
        # whether to `docker exec`. Pass env as a quoted prefix.
        _cp_ssh_opts
        local envprefix="" kv
        for kv in "${envv[@]}"; do
            envprefix+=" $(printf '%q' "$kv")"
        done
        ssh "${CP_SSH_OPTS[@]}" "${CP_USER}@${CP_HOST}" \
            "env${envprefix} timeout ${timeout} bash -lc $(printf '%q' "$run")"
        return $?
    fi

    # where=runner: run in the retained build clone (D2) when present,
    # else in the current directory (local source / no clone).
    local rundir="${CP_BUILD_DIR:-$PWD}"
    ( cd "$rundir" && timeout "$timeout" env "${envv[@]}" bash -c "$run" )
    return $?
}

# ─── Wait for the deployed service to be Docker-healthy ────
# Usage: cp_wait_healthy
# Returns: 0 healthy / no-op; 10 = timeout (caller exits 10).
cp_wait_healthy() {
    local mode="${CP_WAIT_HEALTHY:-auto}"
    [[ "$mode" == "false" ]] && return 0

    _cp_ssh_opts
    local svc="${CP_COMPOSE_SERVICE}"
    local insp="docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' ${svc} 2>/dev/null || echo missing"

    local st
    st=$(ssh "${CP_SSH_OPTS[@]}" "${CP_USER}@${CP_HOST}" "$insp" 2>/dev/null || echo missing)
    if [[ "$st" == "none" ]]; then
        # No healthcheck defined. Default (auto) ⇒ no-op.
        if [[ "$mode" == "true" ]]; then
            lib_log_info "wait_healthy=true but ${svc} has no healthcheck — skipping"
        else
            lib_log_info "${svc} has no healthcheck — wait-for-healthy skipped"
        fi
        return 0
    fi

    local timeout="${CP_HEALTH_TIMEOUT:-150}" elapsed=0 interval=5
    lib_log_info "Waiting for ${svc} to be healthy (timeout ${timeout}s)..."
    while :; do
        st=$(ssh "${CP_SSH_OPTS[@]}" "${CP_USER}@${CP_HOST}" "$insp" 2>/dev/null || echo missing)
        [[ "$st" == "healthy" ]] && { lib_log_success "${svc} healthy"; return 0; }
        if [[ "$elapsed" -ge "$timeout" ]]; then
            lib_log_error "${svc} not healthy after ${timeout}s (last: ${st})"
            return 10
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
}

# ─── Outcome notifier (finalizer) ──────────────────────────
# Usage: cp_notify <success|failed|aborted> <failed_stage> <exit_code> <duration_s>
# Generic command (D18), non-blocking (D20): never changes exit code,
# never stalls; all errors swallowed.
cp_notify() {
    local status="$1" stage="${2:-}" code="${3:-0}" dur="${4:-0}"
    local run="${CP_NOTIFY_RUN:-}"
    [[ -z "$run" ]] && return 0

    # Event filter (D19): notify.on
    case " ${CP_NOTIFY_ON:-success failed aborted} " in
        *" ${status} "*) ;;
        *) return 0 ;;
    esac

    # Resolve relative notifier path against the config dir.
    if [[ "$run" != /* && -n "${CP_CONFIG_FILE:-}" ]]; then
        local cfgdir
        cfgdir="$(dirname "$CP_CONFIG_FILE")"
        [[ -f "${cfgdir}/${run%% *}" ]] && run="${cfgdir}/${run}"
    fi

    local -a envv=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && envv+=("$line")
    done < <(_cp_hook_envkv \
        "CP_STATUS=${status}" \
        "CP_FAILED_STAGE=${stage}" \
        "CP_EXIT_CODE=${code}" \
        "CP_DURATION_S=${dur}")

    lib_log_info "notify (${status}) → ${run%% *}"
    # Non-blocking: own timeout, swallow everything, always succeed.
    ( timeout 25 env "${envv[@]}" bash -c "$run" ) >/dev/null 2>&1 \
        || lib_log_info "notifier failed/timed out (ignored, non-blocking)"
    return 0
}

# ─── Cleanup a retained build clone (if any) ───────────────
_cp_cleanup_clone() {
    if [[ -n "${CP_BUILD_DIR:-}" && "${CP_BUILD_DIR}" == /tmp/* && -d "${CP_BUILD_DIR}" ]]; then
        rm -rf "${CP_BUILD_DIR}"
        lib_log_info "Cleaned up build directory"
    fi
}
