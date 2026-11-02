#!/usr/bin/env bash
# =============================================================================
# SonarQube API helper library (Phase 5)
#
# All API calls execute INSIDE the sonarqube container against
# http://localhost:9000/api — no host TLS trust, no DNS dependency, port never
# exposed. SonarQube Web API is form-parameter based (not JSON bodies), so
# sq_api posts application/x-www-form-urlencoded data. Requires: jq on host.
#
# Sourced AFTER scripts/lib/common.sh (ROOT_DIR, load_env, log_*, uri_encode,
# append_secret, gen_secret expected).
# =============================================================================

SONAR_API="http://localhost:9000/api"

sq_compose_exec() { # runs a command inside the sonarqube container
  ( cd "$ROOT_DIR" && docker compose -f docker-compose.yml exec -T sonarqube "$@" )
}

load_sonar_secrets() {
  local f
  for f in sonar.env sonar-jenkins.env; do
    [[ -f "$ROOT_DIR/secrets/$f" ]] && { set -a; source "$ROOT_DIR/secrets/$f"; set +a; }
  done
}

# Auth precedence: SONAR_ADMIN_PASSWORD (basic admin) once bootstrapped.
sq_curl_auth() { # echoes curl auth args for the admin account
  if [[ -n "${SONAR_ADMIN_PASSWORD:-}" ]]; then
    echo "-u admin:${SONAR_ADMIN_PASSWORD}"
  else
    echo "-u admin:admin"
  fi
}

sq_api() { # METHOD /path [form-data-string]  → body on stdout (auth: admin)
  local method="$1" path="$2" data="${3:-}"
  local curl_args=(curl -sS --max-time 60 -X "$method" $(sq_curl_auth))
  [[ -n "$data" ]] && curl_args+=(-H "Content-Type: application/x-www-form-urlencoded" --data "$data")
  sq_compose_exec "${curl_args[@]}" "${SONAR_API}${path}"
}

sq_api_rc() { # like sq_api but prints "HTTPCODE<newline>BODY"
  local method="$1" path="$2" data="${3:-}" auth="${4:-}"
  local curl_args=(curl -sS --max-time 60 -o /tmp/sq-body -w '%{http_code}' -X "$method")
  [[ -n "$auth" ]] && curl_args+=(-u "$auth") || curl_args+=($(sq_curl_auth))
  [[ -n "$data" ]] && curl_args+=(-H "Content-Type: application/x-www-form-urlencoded" --data "$data")
  local code
  code="$(sq_compose_exec "${curl_args[@]}" "${SONAR_API}${path}")"
  echo "$code"
  sq_compose_exec cat /tmp/sq-body
}

sq_validate_auth() { # login:password → 0 if SonarQube accepts the credentials
  local out
  out="$(sq_compose_exec curl -sS -m 10 -u "$1" "${SONAR_API}/authentication/validate" 2>/dev/null || true)"
  [[ "$out" == *'"valid":true'* ]]
}

wait_for_sonar() {
  log_info "waiting for SonarQube to reach status UP (first boot runs DB migrations, ~2–5 min)…"
  local deadline=$(( $(date +%s) + 1200 )) status=""
  while :; do
    status="$(sq_compose_exec curl -sS -m 5 "${SONAR_API}/system/status" 2>/dev/null | jq -r '.status // empty' || true)"
    case "$status" in
      UP) log_ok "SonarQube is UP"; return 0 ;;
      DB_MIGRATION_NEEDED|DB_MIGRATION_RUNNING) : ;; # keep waiting
      "") : ;;                                        # not answering yet
      *) log_warn "SonarQube status: ${status} (continuing to wait)";;
    esac
    [[ $(date +%s) -ge $deadline ]] && die "SonarQube not UP within 20 minutes — check: docker compose logs sonarqube"
    sleep 10
  done
}
