# lib/bluegreen.sh — blue/green deploy strategy
#
# Guarantee: zero unavailability from a deploy; a bad new version
# never takes traffic; the old color keeps serving until dev fixes.
# See docs/features/blue-green/SPEC.md + PLAN.md. All host ops via ssh.
# Generic: the tool only flips an "active service" pointer in a
# consumer-owned Traefik dynamic template; it never knows the Host/TLS.

# ─── Remote layout ────────────────────────────────────────
_cp_bg_remote_dir()   { echo "${CP_DEPLOY_PATH}/${CP_STACK}"; }
_cp_bg_state_file()   { echo "$(_cp_bg_remote_dir)/.cp-active-color-${CP_COMPOSE_SERVICE}"; }
_cp_bg_dynamic_tmpl() { echo "$(_cp_bg_remote_dir)/dynamic/${CP_COMPOSE_SERVICE}.yml.tmpl"; }
_cp_bg_dynamic_file() { echo "$(_cp_bg_remote_dir)/dynamic/${CP_COMPOSE_SERVICE}.yml"; }

_cp_bg_ssh() { _cp_ssh_opts; ssh "${CP_SSH_OPTS[@]}" "${CP_USER}@${CP_HOST}" "$@"; }

# ─── State (D21): per-service host file; derive if absent ──
cp_bg_state_read() {
    _cp_bg_ssh "cat $(_cp_bg_state_file) 2>/dev/null || true" 2>/dev/null | tr -d '[:space:]'
}
cp_bg_state_write() {
    local color="$1" f; f="$(_cp_bg_state_file)"
    _cp_bg_ssh "printf '%s' '${color}' > '${f}.tmp' && mv -f '${f}.tmp' '${f}'"
}

# Resolve active/target colors. Exports CP_BG_ACTIVE, CP_BG_TARGET,
# CP_BG_BOOTSTRAP. Empty state ⇒ bootstrap (D26): first color = blue.
cp_bg_resolve() {
    local active; active="$(cp_bg_state_read)"
    if [[ "$active" != "blue" && "$active" != "green" ]]; then
        CP_BG_ACTIVE=""; CP_BG_TARGET="blue"; CP_BG_BOOTSTRAP=1
        lib_log_info "blue/green: no active color → bootstrap (target=blue)"
    else
        CP_BG_ACTIVE="$active"
        CP_BG_TARGET=$([[ "$active" == "blue" ]] && echo green || echo blue)
        CP_BG_BOOTSTRAP=0
        lib_log_info "blue/green: active=${CP_BG_ACTIVE} → target=${CP_BG_TARGET}"
    fi
    export CP_BG_ACTIVE CP_BG_TARGET CP_BG_BOOTSTRAP
}

# ─── Push stack files (mirrors cp_deploy copy block) ──────
# Echoes the `-f <file>` compose flags.
cp_bg_push_stack() {
    local remote_dir; remote_dir="$(_cp_bg_remote_dir)"
    _cp_ssh_opts
    ssh "${CP_SSH_OPTS[@]}" "${CP_USER}@${CP_HOST}" "mkdir -p ${remote_dir}/dynamic"
    if [[ -n "${CP_ENV_FILE:-}" && -f "$CP_ENV_FILE" ]]; then
        scp "${CP_SSH_OPTS[@]}" "$CP_ENV_FILE" "${CP_USER}@${CP_HOST}:${remote_dir}/.env" >/dev/null
    fi
    local flags="" file first_dir=""
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        [[ -z "$first_dir" ]] && first_dir="$(dirname "$file")"
        scp "${CP_SSH_OPTS[@]}" "$file" "${CP_USER}@${CP_HOST}:${remote_dir}/$(basename "$file")" >/dev/null
        flags+=" -f $(basename "$file")"
    done <<< "$CP_COMPOSE_FILES"
    # Consumer-owned Traefik dynamic templates live next to the compose
    # file (<composedir>/dynamic/*.tmpl). Ship them so cp_bg_flip can
    # render them on the host. Versioned in the consumer repo.
    if [[ -n "$first_dir" && -d "${first_dir}/dynamic" ]]; then
        local t
        for t in "${first_dir}/dynamic"/*; do
            [[ -f "$t" ]] || continue
            scp "${CP_SSH_OPTS[@]}" "$t" "${CP_USER}@${CP_HOST}:${remote_dir}/dynamic/$(basename "$t")" >/dev/null
        done
    fi
    echo "$flags"
}

# ─── Bring up a color (idle, no public router) ────────────
cp_bg_up_color() {
    local color="$1" svc="${CP_COMPOSE_SERVICE}-$1" flags rd
    rd="$(_cp_bg_remote_dir)"
    flags="$(cp_bg_push_stack)"
    lib_log_info "blue/green: bringing up ${svc} (idle, no traffic)"
    _cp_bg_ssh "cd ${rd} && docker compose ${flags} pull ${svc} && docker compose ${flags} up -d --no-deps --force-recreate ${svc}"
}

# ─── Smoke the idle color (D10: internal, via SSH tunnel) ─
# Reuses the Phase A post hook unchanged: opens an SSH -L tunnel to
# the idle container's IP:port and overrides SMOKE_BASE_URL.
cp_bg_smoke_idle() {
    local svc="${CP_COMPOSE_SERVICE}-${CP_BG_TARGET}" ip lport rc
    ip="$(_cp_bg_ssh "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' ${svc} 2>/dev/null" | awk '{print $1}')"
    if [[ -z "$ip" ]]; then lib_log_error "blue/green: cannot resolve ${svc} IP"; return 1; fi
    lport=$(( ( RANDOM % 20000 ) + 20000 ))
    _cp_ssh_opts
    ssh "${CP_SSH_OPTS[@]}" -L "${lport}:${ip}:${CP_BG_PORT}" -f -N \
        -o ExitOnForwardFailure=yes "${CP_USER}@${CP_HOST}" < /dev/null || {
        lib_log_error "blue/green: smoke tunnel failed"; return 1; }
    local tpid; tpid=$(lsof -ti:"${lport}" -sTCP:LISTEN 2>/dev/null | head -1)
    export CP_HOOK_EXTRA_ENV="SMOKE_BASE_URL=http://127.0.0.1:${lport}"
    cp_hook_run post; rc=$?
    unset CP_HOOK_EXTRA_ENV
    [[ -n "$tpid" ]] && kill "$tpid" 2>/dev/null
    return "$rc"
}

# ─── Flip (D22): swap active-service in the dynamic file ──
# Consumer seeds <svc>.yml.tmpl with __CP_ACTIVE_SERVICE__; the tool
# only renders+atomically installs it. Never knows Host/TLS.
cp_bg_flip() {
    local color="$1" svc="${CP_COMPOSE_SERVICE}-$1"
    local tmpl df; tmpl="$(_cp_bg_dynamic_tmpl)"; df="$(_cp_bg_dynamic_file)"
    _cp_bg_ssh "test -f '${tmpl}'" || { lib_log_error "blue/green: missing dynamic template ${tmpl}"; return 1; }
    _cp_bg_ssh "sed 's/__CP_ACTIVE_SERVICE__/${svc}/g' '${tmpl}' > '${df}.tmp' && mv -f '${df}.tmp' '${df}'" || return 1
    cp_bg_state_write "$color" || return 1
    lib_log_success "blue/green: flipped ${CP_COMPOSE_SERVICE} → ${color}"
}

# ─── Soak + retire old color (D24/D23/D25) ────────────────
cp_bg_soak()   { local s="${CP_BG_SOAK:-60}"; lib_log_info "blue/green: soak ${s}s (old color stays hot)"; sleep "$s"; }
cp_bg_retire() {
    local color="$1" svc="${CP_COMPOSE_SERVICE}-$1" flags rd
    [[ "${CP_BG_RETIRE:-true}" != "true" ]] && { lib_log_info "blue/green: retire_old=false, keeping ${svc}"; return 0; }
    [[ -z "$color" ]] && return 0
    rd="$(_cp_bg_remote_dir)"; flags="$(cp_bg_push_stack)"
    lib_log_info "blue/green: retiring old color ${svc}"
    _cp_bg_ssh "cd ${rd} && docker compose ${flags} rm -fs ${svc}" || true
}

# ─── Manual kill-switch (bin: flip-back) ──────────────────
cp_bg_flip_back() {
    cp_bg_resolve
    if [[ -z "$CP_BG_ACTIVE" ]]; then lib_log_error "flip-back: no active color recorded"; return 1; fi
    local other="$CP_BG_TARGET" svc="${CP_COMPOSE_SERVICE}-${CP_BG_TARGET}"
    local running
    running="$(_cp_bg_ssh "docker inspect -f '{{.State.Running}}' ${svc} 2>/dev/null || echo false")"
    if [[ "$running" != "true" ]]; then
        lib_log_error "flip-back: ${svc} is not running (already retired) — redeploy instead"; return 1
    fi
    lib_log_info "flip-back: ${CP_COMPOSE_SERVICE} ${CP_BG_ACTIVE} → ${other}"
    cp_bg_flip "$other" || return 1
    cp_notify "rolled-back" "flip-back" 0 0 || true
}
