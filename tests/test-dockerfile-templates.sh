#!/usr/bin/env bash
set -uo pipefail
# Tests for the built-in Dockerfile templates (templates/dockerfiles/*).
# Static sanity per template + one integration test through config.sh to
# confirm the resolver picks the built-in when no consumer override exists.

PASS=0; FAIL=0; TOTAL=0
assert() {
    TOTAL=$((TOTAL+1))
    if eval "$1"; then echo "  PASS: $2"; PASS=$((PASS+1))
    else echo "  FAIL: $2"; FAIL=$((FAIL+1)); fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES="${REPO_DIR}/templates/dockerfiles"

TEMPLATES_LIST=(nextjs nestjs react-nginx static-nginx)

echo "1. Built-in Dockerfile templates present"
for t in "${TEMPLATES_LIST[@]}"; do
    assert "[ -s '$TEMPLATES/${t}.Dockerfile' ]" "${t}.Dockerfile exists & non-empty"
done

echo "2. Each template declares ARG, FROM, captures build_commit, has HEALTHCHECK"
for t in "${TEMPLATES_LIST[@]}"; do
    assert "grep -q '^ARG '         '$TEMPLATES/${t}.Dockerfile'" "${t}: has ARG"
    assert "grep -q '^FROM '        '$TEMPLATES/${t}.Dockerfile'" "${t}: has FROM"
    assert "grep -q 'build_commit'  '$TEMPLATES/${t}.Dockerfile'" "${t}: captures build_commit"
    assert "grep -q 'HEALTHCHECK'   '$TEMPLATES/${t}.Dockerfile'" "${t}: declares HEALTHCHECK"
done

echo "3. nestjs: prod-only node_modules stage + node dist/main.js entrypoint"
assert "grep -q 'AS prod-deps'      '$TEMPLATES/nestjs.Dockerfile'" "nestjs: has prod-deps stage"
assert "grep -q 'node.*dist/main\\.js' '$TEMPLATES/nestjs.Dockerfile'" "nestjs: starts node dist/main.js"
assert "grep -q 'USER \\\${APP_UID}' '$TEMPLATES/nestjs.Dockerfile'" "nestjs: runs as non-root"

echo "4. react-nginx: builder stage + nginx runtime + html root"
assert "grep -q 'AS builder' '$TEMPLATES/react-nginx.Dockerfile'" "react-nginx: has builder stage"
assert "grep -q 'NGINX_IMAGE' '$TEMPLATES/react-nginx.Dockerfile'" "react-nginx: parameterizes nginx image"
assert "grep -q '/usr/share/nginx/html' '$TEMPLATES/react-nginx.Dockerfile'" "react-nginx: copies to nginx html root"

echo "5. static-nginx: no builder, single nginx stage"
assert "! grep -q 'AS builder' '$TEMPLATES/static-nginx.Dockerfile'" "static-nginx: no builder stage"
assert "grep -q '/usr/share/nginx/html' '$TEMPLATES/static-nginx.Dockerfile'" "static-nginx: copies to nginx html root"

echo "6. Integration: config.sh resolves each name to its built-in"
# Use top-level $HOME (not /tmp, not ~/.cache) so a snap-confined yq can
# read the fixture — some yq snaps' home plug excludes hidden dirs.
TMPD="$(mktemp -d -p "$HOME" cp-test-XXXXXX)"; trap 'rm -rf "$TMPD"' EXIT
cat > "$TMPD/compose-publisher.yml" <<'YAML'
environments:
  dev:
    host: 0.0.0.0
    ssh_key: /tmp/k
    branch: develop
components:
  cnestjs:      { source: 'git@github.com:x/x.git', dockerfile: nestjs,       compose_service: cn }
  creactnginx:  { source: 'git@github.com:x/x.git', dockerfile: react-nginx,  compose_service: cr }
  cstaticnginx: { source: 'git@github.com:x/x.git', dockerfile: static-nginx, compose_service: cs }
YAML
# yq's dot-accessor doesn't like hyphens in component names (interpreted as
# subtraction). The template *file names* still have hyphens — only the
# fixture component names are dash-free.
declare -A want=( [cnestjs]=nestjs [creactnginx]=react-nginx [cstaticnginx]=static-nginx )
for comp in cnestjs creactnginx cstaticnginx; do
    expected="${TEMPLATES}/${want[$comp]}.Dockerfile"
    out=$(bash -c "
      cd '$TMPD'
      export CP_TEMPLATES_DIR='${REPO_DIR}/templates'
      source \"\${BASH_LIBRARY_PATH:-\${HOME}/.local/lib/bash-library}/lib-loader.sh\"
      source '${REPO_DIR}/lib/config.sh'
      config_load_component '$comp' >/dev/null 2>&1
      echo \"\$CP_DOCKERFILE\"
    " 2>&1 | tail -1)
    assert "[ \"$out\" = \"$expected\" ]" "config_load_component('${comp}') -> built-in ${want[$comp]}.Dockerfile"
done

echo "============================================"
echo "Results: ${PASS} passed, ${FAIL} failed (${TOTAL} total)"
echo "============================================"
[[ "$FAIL" -eq 0 ]]
