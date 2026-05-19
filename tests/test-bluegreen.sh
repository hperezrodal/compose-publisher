#!/usr/bin/env bash
set -uo pipefail

# Tests for the blue/green strategy. Self-contained: all externals
# (bash-library, config, build/transfer, ssh, Traefik) are stubbed.
# Validates the guarantee: a failed green is NEVER flipped, the old
# color keeps serving; backward-compat for strategy=recreate.

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
refute_contains() {
    TOTAL_COUNT=$((TOTAL_COUNT+1))
    if [[ "$1" != *"$2"* ]]; then echo "  PASS: $3"; PASS_COUNT=$((PASS_COUNT+1))
    else echo "  FAIL: $3"; echo "    expected NOT to contain: '$2'"; FAIL_COUNT=$((FAIL_COUNT+1)); fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

run_case() {
    REPO_DIR="$REPO_DIR" bash -c '
        set -uo pipefail
        lib_log_info(){ echo "[i] $*"; }; lib_log_error(){ echo "[E] $*"; }
        lib_log_success(){ echo "[ok] $*"; }
        lib_log_header_starting(){ :; }; lib_log_header_done(){ :; }
        lib_validate_params(){ :; }
        config_load_env(){ :; }; config_load_component(){ :; }
        source "$REPO_DIR/lib/hooks.sh"
        source "$REPO_DIR/lib/bluegreen.sh"
        source "$REPO_DIR/lib/deploy.sh"
        # ── stub infra + bg leaves ──
        cp_build(){ echo "STAGE:build"; return ${MOCK_BUILD:-0}; }
        cp_transfer(){ echo "STAGE:transfer"; return ${MOCK_TRANSFER:-0}; }
        cp_hook_run(){ echo "STAGE:hook:$1"; return ${MOCK_HOOK:-0}; }
        cp_wait_healthy(){ echo "STAGE:health:${CP_COMPOSE_SERVICE}"; return ${MOCK_HEALTH:-0}; }
        cp_notify(){ echo "NOTIFY=$1/$2/$3"; }
        _cp_cleanup_clone(){ :; }
        cp_bg_state_read(){ printf "%s" "${MOCK_STATE:-}"; }
        cp_bg_state_write(){ echo "STATE_WRITE:$1"; }
        cp_bg_up_color(){ echo "STAGE:up:$1"; return ${MOCK_BGUP:-0}; }
        cp_bg_smoke_idle(){ echo "STAGE:smoke:${CP_BG_TARGET}"; return ${MOCK_SMOKE:-0}; }
        cp_bg_flip(){ echo "STAGE:flip:$1"; return ${MOCK_FLIP:-0}; }
        cp_bg_soak(){ echo "STAGE:soak"; }
        cp_bg_retire(){ echo "STAGE:retire:$1"; }
        CP_COMPOSE_SERVICE=web; CP_BG_SOAK=0; CP_BG_RETIRE=true
        '"$1"'
    ' 2>&1
}

echo "1. cp_bg_resolve"
out=$(run_case 'MOCK_STATE="" cp_bg_resolve; echo "A=[$CP_BG_ACTIVE] T=$CP_BG_TARGET B=$CP_BG_BOOTSTRAP"')
assert_contains "$out" "A=[] T=blue B=1" "empty state → bootstrap, target blue"
out=$(run_case 'MOCK_STATE=blue cp_bg_resolve; echo "A=$CP_BG_ACTIVE T=$CP_BG_TARGET B=$CP_BG_BOOTSTRAP"')
assert_contains "$out" "A=blue T=green B=0" "active blue → target green"
out=$(run_case 'MOCK_STATE=green cp_bg_resolve; echo "A=$CP_BG_ACTIVE T=$CP_BG_TARGET B=$CP_BG_BOOTSTRAP"')
assert_contains "$out" "A=green T=blue B=0" "active green → target blue"

echo "2. blue/green success (normal: active blue → flip green + soak/retire)"
out=$(run_case 'MOCK_STATE=blue CP_STRATEGY=blue-green cp_pipeline_deploy_bg web dev 100; echo "RC=$?"')
assert_contains "$out" "STAGE:up:green"      "brings up idle green"
assert_contains "$out" "STAGE:health:web-green" "waits health on green (color-scoped)"
assert_contains "$out" "STAGE:smoke:green"   "smokes green pre-flip"
assert_contains "$out" "STAGE:flip:green"    "flips to green"
assert_contains "$out" "STAGE:soak"          "soak (non-bootstrap)"
assert_contains "$out" "STAGE:retire:blue"   "retires old blue"
assert_contains "$out" "NOTIFY=success/flip:green/0" "notify success/flip:green"
assert_contains "$out" "RC=0"                "success rc 0"

echo "3. bootstrap (no state → up blue, no flip-of-old, no soak/retire)"
out=$(run_case 'MOCK_STATE="" CP_STRATEGY=blue-green cp_pipeline_deploy_bg web dev 100; echo "RC=$?"')
assert_contains "$out" "STAGE:up:blue"   "bootstrap brings up blue"
assert_contains "$out" "STAGE:flip:blue" "bootstrap points router at blue"
refute_contains "$out" "STAGE:soak"      "bootstrap: no soak"
refute_contains "$out" "STAGE:retire"    "bootstrap: nothing to retire"
assert_contains "$out" "RC=0"            "bootstrap rc 0"

echo "4. GUARANTEE: green health fails → NO flip, exit 11"
out=$(run_case 'MOCK_STATE=blue MOCK_HEALTH=1 CP_STRATEGY=blue-green cp_pipeline_deploy_bg web dev 100; echo "RC=$?"')
refute_contains "$out" "STAGE:flip"   "green unhealthy → never flips"
refute_contains "$out" "STAGE:retire" "green unhealthy → old blue NOT retired"
assert_contains "$out" "NOTIFY=failed/bg-health/11" "notify failed/bg-health/11"
assert_contains "$out" "RC=11"        "green health fail → exit 11 (blue serving)"

echo "5. GUARANTEE: green smoke fails → NO flip, exit 11"
out=$(run_case 'MOCK_STATE=green MOCK_SMOKE=1 CP_STRATEGY=blue-green cp_pipeline_deploy_bg web dev 100; echo "RC=$?"')
assert_contains "$out" "STAGE:smoke:blue" "smoked the idle (blue) target"
refute_contains "$out" "STAGE:flip"   "green smoke fail → never flips"
assert_contains "$out" "NOTIFY=failed/bg-smoke/11" "notify failed/bg-smoke/11"
assert_contains "$out" "RC=11"        "green smoke fail → exit 11"

echo "6. flip itself fails → exit 11, old still serving"
out=$(run_case 'MOCK_STATE=blue MOCK_FLIP=1 CP_STRATEGY=blue-green cp_pipeline_deploy_bg web dev 100; echo "RC=$?"')
assert_contains "$out" "NOTIFY=failed/flip/11" "flip fail → notify failed/flip/11"
refute_contains "$out" "STAGE:retire" "flip fail → old NOT retired"
assert_contains "$out" "RC=11"        "flip fail → exit 11"

echo "7. pre_deploy abort (8) and build failure propagate"
out=$(run_case 'MOCK_STATE=blue MOCK_HOOK=1 CP_STRATEGY=blue-green cp_pipeline_deploy_bg web dev 100; echo "RC=$?"')
assert_contains "$out" "NOTIFY=aborted/pre/8" "pre fail → aborted/pre/8"
refute_contains "$out" "STAGE:up"  "pre abort → nothing brought up"
assert_contains "$out" "RC=8"      "pre fail → exit 8"
out=$(run_case 'MOCK_STATE=blue MOCK_BUILD=3 CP_STRATEGY=blue-green cp_pipeline_deploy_bg web dev 100; echo "RC=$?"')
assert_contains "$out" "NOTIFY=failed/build/3" "build fail → failed/build/3"
refute_contains "$out" "STAGE:flip" "build fail → no flip"
assert_contains "$out" "RC=3"      "build failure propagates"

echo "8. backward-compat: strategy=recreate uses the Phase A path"
out=$(run_case 'cp_deploy(){ echo "STAGE:recreate-up"; }
  CP_STRATEGY=recreate cp_pipeline_deploy web dev; echo "RC=$?"')
assert_contains "$out" "STAGE:recreate-up" "recreate → Phase A cp_deploy path"
refute_contains "$out" "STAGE:up:green"    "recreate → no blue/green color up"
refute_contains "$out" "STAGE:flip"        "recreate → no flip"
assert_contains "$out" "RC=0"              "recreate path rc 0"
out=$(run_case 'cp_deploy(){ echo "STAGE:recreate-up"; }
  CP_STRATEGY=blue-green cp_pipeline_deploy web dev; echo "RC=$?"')
assert_contains "$out" "STAGE:flip:" "strategy=blue-green via cp_pipeline_deploy delegates to bg"

echo "9. flip-back kill-switch"
out=$(run_case '
  _cp_bg_ssh(){ echo "true"; }   # other color running
  cp_bg_flip(){ echo "FLIP:$1"; }
  MOCK_STATE=green cp_bg_flip_back; echo "RC=$?"')
assert_contains "$out" "FLIP:blue" "flip-back: green active → flip to blue"
assert_contains "$out" "NOTIFY=rolled-back/flip-back/0" "flip-back notifies rolled-back"
out=$(run_case '
  _cp_bg_ssh(){ echo "false"; }  # other color NOT running
  cp_bg_flip(){ echo "FLIP:$1"; }
  MOCK_STATE=green cp_bg_flip_back; echo "RC=$?"')
assert_contains "$out" "not running" "flip-back errors if other color retired"
refute_contains "$out" "FLIP:" "flip-back: no flip when other color gone"

echo "======================================="
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed (${TOTAL_COUNT} total)"
echo "======================================="
[[ "$FAIL_COUNT" -eq 0 ]]
