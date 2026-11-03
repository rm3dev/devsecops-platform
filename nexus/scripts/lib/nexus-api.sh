#!/usr/bin/env bash
# =============================================================================
# Nexus Repository REST helper library (Phase 5)
#
# All API calls execute INSIDE the nexus container against
# http://localhost:8081/service/rest — no host TLS trust, no DNS dependency,
# port never exposed. Requires: jq on the host.
#
# Sourced AFTER scripts/lib/common.sh (ROOT_DIR, load_env, log_*, uri_encode,
# append_secret, gen_secret expected).
# =============================================================================

NEXUS_API="http://localhost:8081/service/rest/v1"

nx_compose_exec() { # runs a command inside the nexus container
  ( cd "$ROOT_DIR" && docker compose -f docker-compose.yml exec -T nexus "$@" )
}

load_nexus_secrets() {
  local f
  for f in nexus.env nexus-jenkins.env; do
    [[ -f "$ROOT_DIR/secrets/$f" ]] && { set -a; source "$ROOT_DIR/secrets/$f"; set +a; }
  done
}

nx_curl_auth() { # echoes basic-auth curl args for the admin account
  echo "-u admin:${NEXUS_ADMIN_PASSWORD:-admin}"
}

nx_api() { # METHOD /path [json-body] [user:pass-override] → body on stdout
  local method="$1" path="$2" data="${3:-}" auth="${4:-}"
  local curl_args=(curl -sS --max-time 120 -X "$method")
  [[ -n "$auth" ]] && curl_args+=(-u "$auth") || curl_args+=($(nx_curl_auth))
  [[ -n "$data" ]] && curl_args+=(-H "Content-Type: application/json" --data "$data")
  nx_compose_exec "${curl_args[@]}" "${NEXUS_API}${path}"
}

nx_api_rc() { # like nx_api but prints "HTTPCODE<newline>BODY"
  local method="$1" path="$2" data="${3:-}" auth="${4:-}"
  local curl_args=(curl -sS --max-time 120 -o /tmp/nx-body -w '%{http_code}' -X "$method")
  [[ -n "$auth" ]] && curl_args+=(-u "$auth") || curl_args+=($(nx_curl_auth))
  [[ -n "$data" ]] && curl_args+=(-H "Content-Type: application/json" --data "$data")
  local code
  code="$(nx_compose_exec "${curl_args[@]}" "${NEXUS_API}${path}")"
  echo "$code"
  nx_compose_exec cat /tmp/nx-body
}

nx_validate_auth() { # user:password → 0 if Nexus accepts the credentials
  # /security/users requires the Security privilege → valid admin signal;
  # anonymous access is disabled (10-admin-bootstrap), so 200 ⇒ auth OK.
  local code
  code="$(nx_compose_exec curl -sS -m 10 -o /dev/null -w '%{http_code}' -u "$1" \
    "${NEXUS_API}/security/users?source=default" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]]
}

nx_repo_exists() { # repo-name
  nx_api GET "/repositories" | jq -e --arg n "$1" '.[] | select(.name==$n)' >/dev/null 2>&1
}

wait_for_nexus() {
  log_info "waiting for Nexus to become writable (first boot ~2–4 min)…"
  local deadline=$(( $(date +%s) + 1200 ))
  while :; do
    local code
    code="$(nx_compose_exec curl -sS -m 5 -o /dev/null -w '%{http_code}' "${NEXUS_API}/status/writable" 2>/dev/null || echo 000)"
    [[ "$code" == "200" ]] && { log_ok "Nexus is writable"; return 0; }
    [[ $(date +%s) -ge $deadline ]] && die "Nexus not writable within 20 minutes — check: docker compose logs nexus"
    sleep 10
  done
}
