#!/usr/bin/env bash
# =============================================================================
# validate.sh — pre-flight & configuration validation (Phase 2)
#
#   ./scripts/validate.sh              # full pre-flight (before bootstrap/up)
#   ./scripts/validate.sh --versions   # report pinned versions vs compose files
#
# Exit 0 = all checks passed (warnings allowed), exit 1 = at least one FAIL.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

FAILURES=0; WARNINGS=0
pass() { log_ok "$1"; }
warn() { log_warn "$1"; WARNINGS=$((WARNINGS+1)); }
fail() { log_error "$1"; FAILURES=$((FAILURES+1)); }

load_env

echo "${C_BOLD}== DevSecOps platform pre-flight validation ==${C_RESET}"

# ---------------------------------------------------------------- tools ------
require_cmd docker openssl
if docker compose version >/dev/null 2>&1; then
  pass "docker compose v2 present: $(docker compose version --short 2>/dev/null || echo unknown)"
else
  fail "docker compose v2 plugin missing"
fi
DOCKER_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 0.0.0)"
if [[ "$(printf '%s\n27.0.0\n' "$DOCKER_VERSION" | sort -V | head -n1)" == "27.0.0" ]]; then
  pass "Docker Engine $DOCKER_VERSION (>= 27.x)"
else
  fail "Docker Engine $DOCKER_VERSION — need >= 27.x (or daemon unreachable)"
fi

# ------------------------------------------------------------ compose env ----
if [[ -f "$ROOT_DIR/.env" ]]; then
  pass ".env present"
else
  fail ".env missing — run: cp .env.example .env"
fi

REQUIRED_SECRETS=(sonar-db.env sonar.env gitlab.env grafana.env jenkins.env restic_password monitoring.env)
MISSING_SECRETS=()
for s in "${REQUIRED_SECRETS[@]}"; do
  [[ -f "$ROOT_DIR/secrets/$s" ]] || MISSING_SECRETS+=("$s")
done
if [[ ${#MISSING_SECRETS[@]} -eq 0 ]]; then
  pass "all generated secrets present (secrets/)"
else
  warn "missing secrets: ${MISSING_SECRETS[*]} — bootstrap.sh generates them"
fi

# --------------------------------------------------------------- pinning -----
UNPINNED="$(grep -hE '^\s*image:' "$ROOT_DIR"/docker-compose*.yml \
  | sed 's/.*image:\s*//' | grep -E '(:latest\s*$|^[^:$]+\s*$)' || true)"
if [[ -z "$UNPINNED" ]]; then
  pass "no 'latest'/untagged images in compose files"
else
  fail "unpinned images found: $UNPINNED"
fi

# ----------------------------------------------------------- TLS material ----
CERT="$ROOT_DIR/reverse-proxy/certificates/platform-wildcard.crt"
if [[ -f "$CERT" ]]; then
  if openssl x509 -in "$CERT" -noout -checkend 604800 >/dev/null 2>&1; then
    SAN="$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null)"
    if grep -q "*.${PLATFORM_DOMAIN}" <<< "$SAN"; then
      pass "wildcard certificate valid >7d and SAN matches *.${PLATFORM_DOMAIN}"
    else
      fail "certificate SAN does not cover *.${PLATFORM_DOMAIN}: $SAN"
    fi
  else
    fail "certificate expires within 7 days — regenerate (remove reverse-proxy/certificates and re-run bootstrap.sh)"
  fi
else
  warn "wildcard certificate not generated yet — bootstrap.sh will create it"
fi

DYN="$ROOT_DIR/reverse-proxy/configuration/dynamic/dynamic.yml"
if [[ -f "$DYN" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import yaml,sys; yaml.safe_load(open('$DYN'))" 2>/dev/null; then
      pass "Traefik dynamic config present and valid YAML"
    else
      fail "Traefik dynamic config is not valid YAML"
    fi
  else
    pass "Traefik dynamic config present (YAML lint skipped — no python3)"
  fi
else
  warn "Traefik dynamic config not rendered yet — bootstrap.sh generates it"
fi

# --------------------------------------------------------- kernel & ports ----
MAP_COUNT="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
if [[ "$MAP_COUNT" -ge 524288 ]]; then
  pass "vm.max_map_count=$MAP_COUNT (>= 524288, SonarQube/ES requirement)"
else
  fail "vm.max_map_count=$MAP_COUNT — must be >= 524288 (bootstrap.sh sets it)"
fi
MAXNS="$(sysctl -n user.max_user_namespaces 2>/dev/null || echo 0)"
if [[ "$MAXNS" -eq 0 ]]; then
  fail "user namespaces disabled (user.max_user_namespaces=0) — rootless BuildKit will not run"
else
  pass "user.max_user_namespaces=$MAXNS"
fi

for port in "${HTTP_PORT:-80}" "${HTTPS_PORT:-443}" "${GITLAB_SSH_PORT:-2222}"; do
  if command -v ss >/dev/null 2>&1 && ss -tln "( sport = :$port )" 2>/dev/null | grep -q LISTEN; then
    # OK if it is our own already-running platform container
    if docker compose "${COMPOSE_BASE[@]}" ps --status running 2>/dev/null | grep -qE 'traefik|gitlab'; then
      pass "port $port in use by the running platform (expected)"
    else
      fail "port $port already in use by another process"
    fi
  else
    pass "port $port available"
  fi
done

# --------------------------------------------------------------- storage -----
if [[ -d "$DATA_ROOT" ]]; then
  AVAIL_GB="$(df -BG --output=avail "$DATA_ROOT" 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)"
  if [[ "${AVAIL_GB:-0}" -ge 100 ]]; then
    pass "DATA_ROOT=$DATA_ROOT has ${AVAIL_GB}G available"
  elif [[ "${AVAIL_GB:-0}" -ge 40 ]]; then
    warn "DATA_ROOT=$DATA_ROOT has only ${AVAIL_GB}G available (<100G recommended)"
  else
    fail "DATA_ROOT=$DATA_ROOT has only ${AVAIL_GB}G available (<40G minimum)"
  fi
else
  warn "DATA_ROOT=$DATA_ROOT does not exist yet — bootstrap.sh creates it"
fi

# ------------------------------------------------- compose config parse ------
if [[ ${#MISSING_SECRETS[@]} -eq 0 && -f "$ROOT_DIR/.env" ]]; then
  if ( cd "$ROOT_DIR" && docker compose "${COMPOSE_BASE[@]}" --profile all config -q >/dev/null 2>&1 ); then
    pass "docker compose config: all profiles parse successfully"
  else
    fail "docker compose config validation failed:"
    ( cd "$ROOT_DIR" && docker compose "${COMPOSE_BASE[@]}" --profile all config -q ) || true
  fi
fi

# ---------------------------------------------------------------- summary ----
echo
if [[ $FAILURES -eq 0 ]]; then
  echo "${C_GREEN}${C_BOLD}VALIDATION PASSED${C_RESET} (${WARNINGS} warning(s))"
  exit 0
else
  echo "${C_RED}${C_BOLD}VALIDATION FAILED${C_RESET}: $FAILURES failure(s), $WARNINGS warning(s)"
  exit 1
fi
