#!/usr/bin/env bash
set -uo pipefail

# ─── Test framework ────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

assert_eq() {
    local actual="$1"
    local expected="$2"
    local name="$3"
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $name"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: $name"
        echo "    expected: '$expected'"
        echo "    actual:   '$actual'"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_contains() {
    local actual="$1"
    local expected="$2"
    local name="$3"
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    if [[ "$actual" == *"$expected"* ]]; then
        echo "  PASS: $name"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: $name"
        echo "    expected to contain: '$expected'"
        echo "    actual: '$actual'"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_exit_code() {
    local actual="$1"
    local expected="$2"
    local name="$3"
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    if [[ "$actual" -eq "$expected" ]]; then
        echo "  PASS: $name"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: $name"
        echo "    expected exit code: $expected"
        echo "    actual exit code:   $actual"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# ─── Resolve paths ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLI="${REPO_DIR}/bin/compose-publisher"
FIXTURES="${SCRIPT_DIR}/fixtures"

# ─── Setup test directory ──────────────────────────────────
TEST_DIR=$(mktemp -d "${REPO_DIR}/tests/tmp.XXXXXX")
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════
echo ""
echo "compose-publisher CLI Foundation Tests"
echo "======================================="
echo ""

# ─── 1. Version ────────────────────────────────────────────
echo "1. Version"
output=$($CLI --version 2>&1)
assert_contains "$output" "compose-publisher v" "--version shows version string"

output=$($CLI -v 2>&1)
assert_contains "$output" "compose-publisher v" "-v shows version string"
echo ""

# ─── 2. Help ───────────────────────────────────────────────
echo "2. Help"
output=$($CLI --help 2>&1)
assert_contains "$output" "Usage:" "--help shows usage"
assert_contains "$output" "build" "--help lists build command"
assert_contains "$output" "deploy" "--help lists deploy command"
assert_contains "$output" "setup" "--help lists setup command"
assert_contains "$output" "env" "--help lists env command"
assert_contains "$output" "ssh" "--help lists ssh command"

output=$($CLI -h 2>&1)
assert_contains "$output" "Usage:" "-h shows usage"

output=$($CLI 2>&1)
assert_contains "$output" "Usage:" "no args shows help"

output=$($CLI build --help 2>&1)
assert_contains "$output" "compose-publisher build" "build --help shows build usage"

output=$($CLI deploy --help 2>&1)
assert_contains "$output" "compose-publisher deploy" "deploy --help shows deploy usage"

output=$($CLI setup --help 2>&1)
assert_contains "$output" "compose-publisher setup" "setup --help shows setup usage"

output=$($CLI env --help 2>&1)
assert_contains "$output" "compose-publisher env" "env --help shows env usage"
echo ""

# ─── 3. Unknown command ───────────────────────────────────
echo "3. Unknown command"
output=$($CLI foobar 2>&1)
ec=$?
assert_exit_code "$ec" 1 "unknown command exits 1"
assert_contains "$output" "Unknown command: foobar" "unknown command shows error"
assert_contains "$output" "Usage:" "unknown command shows help"
echo ""

# ─── 4. Missing --env ─────────────────────────────────────
echo "4. Missing --env flag"
output=$($CLI build backend 2>&1)
ec=$?
assert_exit_code "$ec" 1 "build without --env exits 1"
assert_contains "$output" "Missing --env" "build without --env shows error"

output=$($CLI deploy backend 2>&1)
ec=$?
assert_exit_code "$ec" 1 "deploy without --env exits 1"

output=$($CLI setup 2>&1)
ec=$?
assert_exit_code "$ec" 1 "setup without --env exits 1"

output=$($CLI env push 2>&1)
ec=$?
assert_exit_code "$ec" 1 "env push without --env exits 1"
echo ""

# ─── 5. Missing component ─────────────────────────────────
echo "5. Missing component"
cd "$TEST_DIR"
cp "$FIXTURES/compose-publisher.yml" .

output=$($CLI build --env dev 2>&1)
ec=$?
assert_exit_code "$ec" 1 "build without component exits 1"
assert_contains "$output" "Missing component" "build without component shows error"

output=$($CLI deploy --env dev 2>&1)
ec=$?
assert_exit_code "$ec" 1 "deploy without component or --all exits 1"
assert_contains "$output" "Missing component or --all" "deploy without component shows error"
echo ""

# ─── 6. Missing config file ───────────────────────────────
echo "6. Missing config file"
cd "$TEST_DIR"
rm -f compose-publisher.yml

output=$($CLI build backend --env dev 2>&1)
ec=$?
assert_exit_code "$ec" 1 "build without config exits 1"
assert_contains "$output" "compose-publisher.yml not found" "missing config shows error"
echo ""

# ─── 7. Env subcommand validation ─────────────────────────
echo "7. Env subcommand validation"
cd "$TEST_DIR"
cp "$FIXTURES/compose-publisher.yml" .

output=$($CLI env --env dev 2>&1)
ec=$?
assert_exit_code "$ec" 1 "env without subcommand exits 1"
assert_contains "$output" "Missing subcommand" "env without subcommand shows error"

output=$($CLI env invalid --env dev 2>&1)
ec=$?
assert_exit_code "$ec" 1 "env with invalid subcommand exits 1"
assert_contains "$output" "Unknown env subcommand" "env invalid subcommand shows error"
echo ""

# ─── 8. Config parser: load environment ───────────────────
echo "8. Config parser: load environment"
cd "$TEST_DIR"
cp "$FIXTURES/compose-publisher.yml" .

output=$(bash -c "
source '${REPO_DIR}/lib/config.sh'
source \"\${BASH_LIBRARY_PATH:-\${HOME}/.local/lib/bash-library}/lib-loader.sh\"
source '${REPO_DIR}/lib/config.sh'
config_load_env 'dev'
echo \"HOST=\${CP_HOST}\"
echo \"USER=\${CP_USER}\"
echo \"BRANCH=\${CP_BRANCH}\"
echo \"DEPLOY_PATH=\${CP_DEPLOY_PATH}\"
" 2>&1)
assert_contains "$output" "HOST=157.245.190.48" "config_load_env parses host"
assert_contains "$output" "USER=root" "config_load_env parses user"
assert_contains "$output" "BRANCH=develop" "config_load_env parses branch"
assert_contains "$output" "DEPLOY_PATH=~/deployment" "config_load_env uses default deploy_path"

# Prod has custom deploy_path
output=$(bash -c "
source \"\${BASH_LIBRARY_PATH:-\${HOME}/.local/lib/bash-library}/lib-loader.sh\"
source '${REPO_DIR}/lib/config.sh'
config_load_env 'prod'
echo \"DEPLOY_PATH=\${CP_DEPLOY_PATH}\"
" 2>&1)
assert_contains "$output" "DEPLOY_PATH=~/deployment/apps" "config_load_env reads custom deploy_path"
echo ""

# ─── 9. Config parser: load component ────────────────────
echo "9. Config parser: load component"
cd "$TEST_DIR"

output=$(bash -c "
source \"\${BASH_LIBRARY_PATH:-\${HOME}/.local/lib/bash-library}/lib-loader.sh\"
source '${REPO_DIR}/lib/config.sh'
config_load_component 'backend'
echo \"SOURCE=\${CP_SOURCE}\"
echo \"TARGET=\${CP_TARGET}\"
echo \"SERVICE=\${CP_COMPOSE_SERVICE}\"
echo \"PLATFORM=\${CP_PLATFORM}\"
" 2>&1)
assert_contains "$output" "SOURCE=git@github.com:example/backend.git" "config_load_component parses source"
assert_contains "$output" "TARGET=production" "config_load_component parses target"
assert_contains "$output" "SERVICE=backend" "config_load_component parses compose_service"
assert_contains "$output" "PLATFORM=linux/amd64" "config_load_component parses platform"

# Frontend: local source, defaults
output=$(bash -c "
source \"\${BASH_LIBRARY_PATH:-\${HOME}/.local/lib/bash-library}/lib-loader.sh\"
source '${REPO_DIR}/lib/config.sh'
config_load_component 'frontend'
echo \"SOURCE=\${CP_SOURCE}\"
echo \"CONTEXT=\${CP_CONTEXT}\"
echo \"PLATFORM=\${CP_PLATFORM}\"
" 2>&1)
assert_contains "$output" "SOURCE=./frontend" "local source parsed correctly"
assert_contains "$output" "CONTEXT=." "context defaults to ."
assert_contains "$output" "PLATFORM=linux/amd64" "platform defaults to linux/amd64"
echo ""

# ─── 10. Config parser: nonexistent env/component ─────────
echo "10. Config parser: nonexistent env/component"
cd "$TEST_DIR"

output=$(bash -c "
source \"\${BASH_LIBRARY_PATH:-\${HOME}/.local/lib/bash-library}/lib-loader.sh\"
source '${REPO_DIR}/lib/config.sh'
config_load_env 'nonexistent'
" 2>&1)
ec=$?
assert_exit_code "$ec" 1 "nonexistent env exits 1"
assert_contains "$output" "not found" "nonexistent env shows error"

output=$(bash -c "
source \"\${BASH_LIBRARY_PATH:-\${HOME}/.local/lib/bash-library}/lib-loader.sh\"
source '${REPO_DIR}/lib/config.sh'
config_load_component 'nonexistent'
" 2>&1)
ec=$?
assert_exit_code "$ec" 1 "nonexistent component exits 1"
assert_contains "$output" "not found" "nonexistent component shows error"
echo ""

# ─── 11. Config parser: branch-to-env resolution ─────────
echo "11. Branch-to-env resolution"
cd "$TEST_DIR"

output=$(bash -c "
source \"\${BASH_LIBRARY_PATH:-\${HOME}/.local/lib/bash-library}/lib-loader.sh\"
source '${REPO_DIR}/lib/config.sh'
echo \$(config_resolve_env_from_branch 'develop')
" 2>&1)
assert_eq "$output" "dev" "develop → dev"

output=$(bash -c "
source \"\${BASH_LIBRARY_PATH:-\${HOME}/.local/lib/bash-library}/lib-loader.sh\"
source '${REPO_DIR}/lib/config.sh'
echo \$(config_resolve_env_from_branch 'main')
" 2>&1)
assert_eq "$output" "prod" "main → prod"

output=$(bash -c "
source \"\${BASH_LIBRARY_PATH:-\${HOME}/.local/lib/bash-library}/lib-loader.sh\"
source '${REPO_DIR}/lib/config.sh'
echo \$(config_resolve_env_from_branch 'nonexistent')
" 2>&1)
assert_eq "$output" "" "nonexistent branch → empty"
echo ""

# ─── 12. Config parser: list components ───────────────────
echo "12. List components"
cd "$TEST_DIR"

output=$(bash -c "
source \"\${BASH_LIBRARY_PATH:-\${HOME}/.local/lib/bash-library}/lib-loader.sh\"
source '${REPO_DIR}/lib/config.sh'
config_list_components
" 2>&1)
assert_contains "$output" "backend" "lists backend"
assert_contains "$output" "frontend" "lists frontend"
echo ""

# ═══════════════════════════════════════════════════════════
echo "======================================="
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed (${TOTAL_COUNT} total)"
echo "======================================="

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
