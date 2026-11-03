#!/usr/bin/env bash
# =============================================================================
# health-check.sh — live platform health matrix (Phase 2)
#
#   ./scripts/health-check.sh           # one-shot report (exit 1 if core down)
#   ./scripts/health-check.sh --wait    # poll until healthy or timeout (10 min)
#
# Probes the public endpoints through Traefik (TLS, internal CA → -k) using
# --resolve so no DNS setup is required on the machine running the check.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_env
require_cmd curl

WAIT_MODE=0
[[ "${1:-}" == "--wait" ]] && WAIT_MODE=1

# monitoring basic-auth (if generated)
MON_AUTH=()
if [[ -f "$ROOT_DIR/secrets/monitoring.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/secrets/monitoring.env"
  MON_AUTH=(-u "${MONITORING_BASIC_AUTH_USER}:${MONITORING_BASIC_AUTH_PASSWORD}")
fi

probe() { # name, host, path, expected-substring-or-http-code, extra curl args...
  local name="$1" host="$2" path="$3" expect="$4"; shift 4
  local url="https://${host}${path}"
  local body code
  body="$(curl -sk --max-time 10 --resolve "${host}:${HTTPS_PORT:-443}:127.0.0.1" \
          -w '\n%{http_code}' "$@" "$url" 2>/dev/null || echo $'\n000')"
  code="$(tail -n1 <<< "$body")"
  body="$(sed '$d' <<< "$body")"
  if [[ "$expect" =~ ^[0-9]{3}$ ]]; then
    [[ "$code" == "$expect" ]] && { printf '%-28s %sUP%s      (HTTP %s)\n' "$name" "$C_GREEN" "$C_RESET" "$code"; return 0; }
  else
    grep -q "$expect" <<< "$body" && { printf '%-28s %sUP%s      (HTTP %s, matched "%s")\n' "$name" "$C_GREEN" "$C_RESET" "$code" "$expect"; return 0; }
  fi
  printf '%-28s %sDOWN%s    (HTTP %s, expected %s)\n' "$name" "$C_RED" "$C_RESET" "$code" "$expect"
  return 1
}

check_all() {
  echo "${C_BOLD}== container state ==${C_RESET}"
  ( cd "$ROOT_DIR" && docker compose "${COMPOSE_BASE[@]}" --profile all ps \
      --format 'table {{.Service}}\t{{.Status}}' 2>/dev/null ) || true
  echo
  echo "${C_BOLD}== endpoint health (via Traefik) ==${C_RESET}"
  local failed=0
  probe "gitlab"     "gitlab.${PLATFORM_DOMAIN}"        "/-/health"            "GitLab OK"   || failed=$((failed+1))
  probe "jenkins"    "jenkins.${PLATFORM_DOMAIN}"       "/login"               "200"         || failed=$((failed+1))
  probe "sonarqube"  "sonar.${PLATFORM_DOMAIN}"         "/api/system/status"   '"status":"UP"' || {
    # during first-boot DB migration SonarQube is not UP yet — report but tolerate
    printf '%-28s %sWARN%s    (status not UP yet — DB migration in progress?)\n' "sonarqube" "$C_YELLOW" "$C_RESET"
  }
  probe "nexus"      "nexus.${PLATFORM_DOMAIN}"         "/service/rest/v1/status" "200"      || failed=$((failed+1))
  probe "grafana"    "grafana.${PLATFORM_DOMAIN}"       "/api/health"          '"database":[[:space:]]*"ok"' || failed=$((failed+1))

  # Vault: report initialized/sealed explicitly (sealed is NOT a failure here —
  # it requires manual unseal by design, architecture D-09)
  local vault_body vault_state
  vault_body="$(curl -sk --max-time 10 --resolve "vault.${PLATFORM_DOMAIN}:${HTTPS_PORT:-443}:127.0.0.1" \
                "https://vault.${PLATFORM_DOMAIN}/v1/sys/health?standbyok=true&sealedcode=200&uninitcode=200" || echo '{}')"
  if grep -q '"initialized":true' <<< "$vault_body" && grep -q '"sealed":false' <<< "$vault_body"; then
    vault_state="${C_GREEN}UP (initialized, unsealed)${C_RESET}"
  elif grep -q '"initialized":true' <<< "$vault_body"; then
    vault_state="${C_YELLOW}SEALED — run: docker compose exec vault vault operator unseal${C_RESET}"
  elif [[ "$vault_body" == "{}" ]]; then
    vault_state="${C_RED}UNREACHABLE${C_RESET}"; failed=$((failed+1))
  else
    vault_state="${C_YELLOW}UNINITIALIZED — run: docker compose exec vault vault operator init -key-shares=5 -key-threshold=3${C_RESET}"
  fi
  printf '%-28s %b\n' "vault" "$vault_state"

  # Optional monitoring routes (basic-auth protected)
  if [[ -n "${MONITORING_BASIC_AUTH_USER:-}" ]]; then
    probe "prometheus"  "prometheus.${PLATFORM_DOMAIN}"  "/-/healthy" "200" "${MON_AUTH[@]}" \
      || printf '%-28s %sSKIP%s    (monitoring profile not running?)\n' "prometheus" "$C_YELLOW" "$C_RESET"
    probe "alertmanager" "alertmanager.${PLATFORM_DOMAIN}" "/-/healthy" "200" "${MON_AUTH[@]}" \
      || true
  fi

  # Registry endpoint: 401 = Nexus reachable but docker-group connector not yet
  # created (Phase 5); 200/401 both count as proxy chain OK.
  local reg_code
  reg_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
    --resolve "registry.${PLATFORM_DOMAIN}:${HTTPS_PORT:-443}:127.0.0.1" \
    "https://registry.${PLATFORM_DOMAIN}/v2/" || echo 000)"
  case "$reg_code" in
    401|200) printf '%-28s %sREACHABLE%s (HTTP %s — 401 until Phase 5 creates docker-group connector)\n' "registry (docker /v2/)" "$C_GREEN" "$C_RESET" "$reg_code" ;;
    *)       printf '%-28s %sPENDING%s  (HTTP %s — expected until Nexus docker connector exists)\n' "registry (docker /v2/)" "$C_YELLOW" "$C_RESET" "$reg_code" ;;
  esac

  return $failed
}

if [[ $WAIT_MODE -eq 1 ]]; then
  DEADLINE=$(( $(date +%s) + 600 ))
  while true; do
    if check_all; then echo; echo "${C_GREEN}${C_BOLD}PLATFORM HEALTHY${C_RESET}"; exit 0; fi
    if [[ $(date +%s) -ge $DEADLINE ]]; then echo; echo "${C_RED}${C_BOLD}TIMEOUT — platform not fully healthy after 10 minutes${C_RESET}"; exit 1; fi
    echo; log_info "not healthy yet — retrying in 30s (first boot takes 5–10 min)"; sleep 30
  done
else
  if check_all; then echo; echo "${C_GREEN}${C_BOLD}CORE SERVICES HEALTHY${C_RESET}"; exit 0
  else echo; echo "${C_RED}${C_BOLD}ONE OR MORE CORE SERVICES ARE DOWN${C_RESET} — see documentation/troubleshooting.md"; exit 1; fi
fi
