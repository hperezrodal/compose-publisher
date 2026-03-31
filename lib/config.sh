# lib/config.sh — compose-publisher.yml config parser

CP_CONFIG_FILE="compose-publisher.yml"

# ─── Read a YAML value with yq, return empty string if null ────
_cp_yq() {
    local result
    result=$(yq eval "$1" "$CP_CONFIG_FILE" 2>/dev/null)
    if [[ "$result" == "null" ]]; then
        echo ""
    else
        echo "$result"
    fi
}

# ─── Load environment config ──────────────────────────────
# Usage: config_load_env "prod"
# Exports: CP_HOST, CP_USER, CP_SSH_KEY, CP_BRANCH, CP_ENV_FILE,
#          CP_DEPLOY_PATH, CP_COMPOSE_FILES
config_load_env() {
    local env="$1"
    lib_validate_params "env" "$env"

    # Check environment exists
    local env_exists
    env_exists=$(_cp_yq ".environments.${env}")
    if [[ -z "$env_exists" ]]; then
        lib_log_error "Environment '${env}' not found in ${CP_CONFIG_FILE}"
        exit 1
    fi

    CP_HOST=$(_cp_yq ".environments.${env}.host")
    CP_USER=$(_cp_yq ".environments.${env}.user")
    CP_USER="${CP_USER:-root}"
    CP_SSH_KEY=$(_cp_yq ".environments.${env}.ssh_key")
    CP_BRANCH=$(_cp_yq ".environments.${env}.branch")
    CP_ENV_FILE=$(_cp_yq ".environments.${env}.env_file")
    CP_DEPLOY_PATH=$(_cp_yq ".environments.${env}.deploy_path")
    CP_DEPLOY_PATH="${CP_DEPLOY_PATH:-~/deployment}"
    CP_REGISTRY_PORT=$(_cp_yq ".environments.${env}.registry_port")
    CP_REGISTRY_PORT="${CP_REGISTRY_PORT:-5000}"

    # Compose files as newline-separated list
    CP_COMPOSE_FILES=$(_cp_yq ".environments.${env}.compose_files[]")

    # Expand ~ in ssh_key (local path)
    CP_SSH_KEY="${CP_SSH_KEY/#\~/$HOME}"

    # NOTE: CP_DEPLOY_PATH keeps ~ as-is — it's used in remote SSH commands
    # where the remote shell expands ~. Do NOT expand locally.

    # Validate required fields
    lib_validate_params \
        "host" "$CP_HOST" \
        "ssh_key" "$CP_SSH_KEY" \
        "branch" "$CP_BRANCH"

    export CP_HOST CP_USER CP_SSH_KEY CP_BRANCH CP_ENV_FILE CP_DEPLOY_PATH CP_COMPOSE_FILES CP_REGISTRY_PORT
}

# ─── Load component config ────────────────────────────────
# Usage: config_load_component "backend"
# Exports: CP_SOURCE, CP_DOCKERFILE, CP_CONTEXT, CP_TARGET,
#          CP_COMPOSE_SERVICE, CP_STACK, CP_PLATFORM
config_load_component() {
    local component="$1"
    lib_validate_params "component" "$component"

    # Check component exists
    local comp_exists
    comp_exists=$(_cp_yq ".components.${component}")
    if [[ -z "$comp_exists" ]]; then
        lib_log_error "Component '${component}' not found in ${CP_CONFIG_FILE}"
        exit 1
    fi

    CP_SOURCE=$(_cp_yq ".components.${component}.source")
    CP_DOCKERFILE=$(_cp_yq ".components.${component}.dockerfile")
    CP_DOCKERFILE="${CP_DOCKERFILE:-Dockerfile}"
    CP_CONTEXT=$(_cp_yq ".components.${component}.context")
    CP_CONTEXT="${CP_CONTEXT:-.}"
    CP_TARGET=$(_cp_yq ".components.${component}.target")
    CP_COMPOSE_SERVICE=$(_cp_yq ".components.${component}.compose_service")
    CP_STACK=$(_cp_yq ".components.${component}.stack")
    CP_STACK="${CP_STACK:-default}"
    CP_PLATFORM=$(_cp_yq ".components.${component}.platform")
    CP_PLATFORM="${CP_PLATFORM:-linux/amd64}"

    lib_validate_params \
        "source" "$CP_SOURCE" \
        "compose_service" "$CP_COMPOSE_SERVICE"

    export CP_SOURCE CP_DOCKERFILE CP_CONTEXT CP_TARGET CP_COMPOSE_SERVICE CP_STACK CP_PLATFORM
}

# ─── Resolve environment from branch ──────────────────────
# Usage: config_resolve_env_from_branch "develop"
# Returns: environment name (e.g. "dev")
config_resolve_env_from_branch() {
    local branch="$1"
    _cp_yq ".environments | to_entries[] | select(.value.branch == \"${branch}\") | .key"
}

# ─── List all components ──────────────────────────────────
# Usage: config_list_components
# Returns: newline-separated component names
config_list_components() {
    _cp_yq ".components | keys | .[]"
}

# ─── SSH options helper ───────────────────────────────────
# Sets CP_SSH_OPTS array. Use as: ssh "${CP_SSH_OPTS[@]}" user@host
# F-006: Use arrays to handle paths with spaces correctly.
_cp_ssh_opts() {
    CP_SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "${CP_SSH_KEY}")
}
