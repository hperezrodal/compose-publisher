#!/usr/bin/env bash
set -uo pipefail

# Tests for deploy lifecycle hooks + wait-for-healthy + notifier.
# Self-contained: all external deps (bash-library, config, build/
# transfer/deploy, ssh) are stubbed. No yq / fixtures / VPS needed.
# Validates the new control flow, exit codes and contracts.

PASS_COUNT=0; FAIL_COUNT=0; TOTAL_COUNT=0
assert_eq() {
    TOTAL_COUNT=$((TOTAL_COUNT+1))
    if [[ "$1" == "$2" ]]; then echo "  PASS: $3"; PASS_COUNT=$((PASS_COUNT+1))
    else echo "  FAIL: $3"; echo "    expected: '$2'"; echo "    actual:   '$1'"; FAIL_COUNT=$((FAIL_COUNT+1)); fi
}
assert_contains() {
    TOTAL_COUNT=$((TOTAL_COUNT+1))
    if [[ "$1" == *"$2"* ]]; then echo "  PASS: $3"; PASS_COUNT=$((PASS_COUNT+1))
    else echo "  FAIL: $3"; echo "    expected to contain: '$2'"; echo "    actual: '$1'"; FAIL_COUNT=$((FAIL_COUNT+1)); fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# One isolated subshell per case: stub externals, source the units,
# then run the snippet ($1).
run_case() {
    REPO_DIR="$REPO_DIR" bash -c '
        set -uo pipefail
        # ── stub bash-library logging ──
        lib_log_info()  { echo "[i] $*"; }
        lib_log_error() { echo "[E] $*"; }
        lib_log_success(){ echo "[ok] $*"; }
        lib_log_header_starting() { :; }
        lib_log_header_done() { :; }
        lib_validate_params() { :; }
        # ── stub config layer (no yq) ──
        config_load_env()       { :; }
        config_load_component() { :; }
        config_hook_env_kv()    { printf "%s\n" "${MOCK_HOOK_KV:-}"; }
        _cp_ssh_opts()          { CP_SSH_OPTS=(-o BatchMode=yes); }
        # ── source units under test ──
        source "$REPO_DIR/lib/hooks.sh"
        source "$REPO_DIR/lib/deploy.sh"
        # ── stub infra for pipeline tests ──
        cp_build()        { echo "STAGE:build";    return ${MOCK_BUILD:-0}; }
        cp_transfer()     { echo "STAGE:transfer"; return ${MOCK_TRANSFER:-0}; }
        cp_deploy()       { echo "STAGE:up";       return ${MOCK_DEPLOY:-0}; }
        '"$1"'
    ' 2>&1
}

echo "1. _cp_runner_hook_needs_clone"
out=$(run_case 'CP_POST_RUN="./s.sh"; CP_POST_WHERE="runner"
  if _cp_runner_hook_needs_clone; then echo NEEDS; else echo NO; fi')
assert_contains "$out" "NEEDS" "runner post hook ⇒ keep clone"
out=$(run_case 'CP_PRE_RUN=""; CP_POST_RUN=""
  if _cp_runner_hook_needs_clone; then echo NEEDS; else echo NO; fi')
assert_contains "$out" "NO" "no hooks ⇒ do not keep clone"
out=$(run_case 'CP_PRE_RUN="b.sh"; CP_PRE_WHERE="host"; CP_POST_RUN=""
  if _cp_runner_hook_needs_clone; then echo NEEDS; else echo NO; fi')
assert_contains "$out" "NO" "host-only hook ⇒ clone not needed by runner"

echo "2. cp_hook_run: skip when no hook"
out=$(run_case 'CP_POST_RUN=""; cp_hook_run post; echo "RC=$?"')
assert_contains "$out" "RC=0" "absent hook ⇒ rc 0 (skip)"

echo "3. cp_hook_run runner: runs in CP_BUILD_DIR with merged env"
out=$(run_case '
  bd=$(mktemp -d)
  cat > "$bd/hook.sh" <<EOS
echo "PWD=\$(pwd) URL=\$SMOKE_URL PHASE=\$CP_HOOK_PHASE COMP=\$CP_COMPONENT"
EOS
  export CP_BUILD_DIR="$bd" CP_COMPONENT="web" CP_ENV="dev"
  CP_POST_RUN="bash hook.sh"; CP_POST_WHERE="runner"; CP_POST_TIMEOUT=10
  MOCK_HOOK_KV="SMOKE_URL=https://d.example.com"
  cp_hook_run post; echo "RC=$?"; rm -rf "$bd"')
assert_contains "$out" "URL=https://d.example.com" "merged hook_env reaches the hook"
assert_contains "$out" "PHASE=post" "CP_HOOK_PHASE injected"
assert_contains "$out" "COMP=web" "CP_* context injected"
assert_contains "$out" "RC=0" "passing runner hook ⇒ rc 0"

echo "4. cp_hook_run runner: failing hook propagates non-zero"
out=$(run_case '
  bd=$(mktemp -d); echo "exit 7" > "$bd/h.sh"
  export CP_BUILD_DIR="$bd"
  CP_POST_RUN="bash h.sh"; CP_POST_WHERE="runner"; CP_POST_TIMEOUT=10
  cp_hook_run post; echo "RC=$?"; rm -rf "$bd"')
assert_contains "$out" "RC=7" "failing hook ⇒ non-zero propagated"

echo "5. cp_notify: event filter + non-blocking"
out=$(run_case '
  CP_NOTIFY_RUN="true"; CP_NOTIFY_ON="failed aborted"
  cp_notify success "" 0 1; echo "RC=$?"')
assert_contains "$out" "RC=0" "status filtered out ⇒ rc 0, not run"
out=$(run_case '
  CP_NOTIFY_RUN="bash -c \"exit 9\""; CP_NOTIFY_ON="success failed aborted"
  cp_notify failed build 5 2; echo "RC=$?"')
assert_contains "$out" "RC=0" "failing notifier ⇒ non-blocking rc 0"
assert_contains "$out" "non-blocking" "non-blocking failure is logged"

echo "6. cp_pipeline_deploy: success path + order + notify"
out=$(run_case '
  cp_wait_healthy(){ echo "STAGE:health"; return 0; }
  cp_notify(){ echo "NOTIFY=$1/$2/$3"; }
  _cp_cleanup_clone(){ echo "CLEANUP"; }
  CP_PRE_RUN=""; CP_POST_RUN=""
  cp_pipeline_deploy web dev; echo "RC=$?"')
assert_contains "$out" "STAGE:build" "runs build"
assert_contains "$out" "STAGE:transfer" "runs transfer"
assert_contains "$out" "STAGE:up" "runs up"
assert_contains "$out" "STAGE:health" "runs wait-healthy"
assert_contains "$out" "NOTIFY=success//0" "success ⇒ notify success"
assert_contains "$out" "CLEANUP" "finalizer cleans clone"
assert_contains "$out" "RC=0" "success ⇒ rc 0"

echo "7. cp_pipeline_deploy: backward-compat order (no hooks)"
seq=$(run_case '
  cp_wait_healthy(){ echo "STAGE:health"; return 0; }
  cp_notify(){ :; }; _cp_cleanup_clone(){ :; }
  CP_PRE_RUN=""; CP_POST_RUN=""
  cp_pipeline_deploy web dev' | grep '^STAGE:' | paste -sd, -)
assert_eq "$seq" "STAGE:build,STAGE:transfer,STAGE:up,STAGE:health" "order = build→transfer→up→health"

echo "8. cp_pipeline_deploy: exit codes"
out=$(run_case '
  cp_wait_healthy(){ return 0; }; cp_notify(){ echo "N=$1/$2/$3"; }; _cp_cleanup_clone(){ :; }
  cp_hook_run(){ [[ "$1" == pre ]] && return 4 || return 0; }
  cp_pipeline_deploy web dev; echo "RC=$?"')
assert_contains "$out" "N=aborted/pre/8" "pre fail ⇒ notify aborted/pre/8"
assert_contains "$out" "RC=8" "pre-hook fail ⇒ exit 8"
assert_eq "$(echo "$out" | grep -c STAGE:build)" "0" "pre-abort ⇒ build never runs"

out=$(run_case '
  cp_wait_healthy(){ return 0; }; cp_notify(){ echo "N=$1/$2/$3"; }; _cp_cleanup_clone(){ :; }
  cp_hook_run(){ [[ "$1" == post ]] && return 3 || return 0; }
  cp_pipeline_deploy web dev; echo "RC=$?"')
assert_contains "$out" "N=failed/post/9" "post fail ⇒ notify failed/post/9"
assert_contains "$out" "RC=9" "post-hook fail ⇒ exit 9 (distinct)"
assert_contains "$out" "STAGE:up" "post-fail still applied the deploy"

out=$(run_case '
  cp_wait_healthy(){ return 10; }; cp_notify(){ echo "N=$1/$2/$3"; }; _cp_cleanup_clone(){ :; }
  CP_PRE_RUN=""; CP_POST_RUN=""
  cp_pipeline_deploy web dev; echo "RC=$?"')
assert_contains "$out" "N=failed/health/10" "health timeout ⇒ notify failed/health/10"
assert_contains "$out" "RC=10" "health timeout ⇒ exit 10"

out=$(run_case '
  cp_wait_healthy(){ return 0; }; cp_notify(){ echo "N=$1/$2/$3"; }; _cp_cleanup_clone(){ :; }
  CP_PRE_RUN=""; CP_POST_RUN=""
  MOCK_BUILD=2 cp_pipeline_deploy web dev; echo "RC=$?"')
assert_contains "$out" "N=failed/build/2" "build fail ⇒ notify failed/build/2"
assert_contains "$out" "RC=2" "build failure propagates code 2"

echo "======================================="
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed (${TOTAL_COUNT} total)"
echo "======================================="
[[ "$FAIL_COUNT" -eq 0 ]]
