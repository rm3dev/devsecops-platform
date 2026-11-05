#!/usr/bin/env bash
# =============================================================================
# 10-enable-nexus-metrics.sh — Nexus scrape target for Prometheus (Phase 10).
#
# Three idempotent actions:
#   1. enable the Nexus "metrics" capability (/service/metrics/prometheus)
#   2. create role  'monitoring-metrics' — ZERO repository/admin privileges
#      (the metrics endpoint only requires ANY authenticated user)
#   3. create user  ${NEXUS_METRICS_USER:-metrics} with the password bootstrap
#      generated into secrets/prometheus/nexus_metrics_password (Prometheus
#      reads that exact file via basic_auth.password_file)
#
# Requires: Nexus up (nexus/scripts/10-admin-bootstrap.sh already run), jq.
# Verify: curl -u metrics:$(cat secrets/prometheus/nexus_metrics_password) \
#         http://<nexus>:8081/service/metrics/prometheus | head
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../scripts/lib/common.sh"
source "$HERE/../../nexus/scripts/lib/nexus-api.sh"
load_env; load_nexus_secrets
require_cmd jq

: "${NEXUS_ADMIN_PASSWORD:?run nexus/scripts/10-admin-bootstrap.sh first}"
PW_FILE="$ROOT_DIR/secrets/prometheus/nexus_metrics_password"
[[ -f "$PW_FILE" ]] || die "$PW_FILE missing — run scripts/bootstrap.sh first"
METRICS_PW="$(cat "$PW_FILE")"
METRICS_USER="${NEXUS_METRICS_USER:-metrics}"

wait_for_nexus

# --- 1. metrics endpoint ------------------------------------------------------
# Nexus >= 3.96 REMOVED the metrics capability: /service/rest/metrics/* is
# built in and requires only ANY authenticated user. Older versions serve
# /service/metrics/* after enabling the capability (typeId varies by version).
# Detect the live path instead of guessing; keep the legacy flow as fallback.
METRICS_PATH=""
for p in "/service/rest/metrics/prometheus" "/service/metrics/prometheus"; do
  code="$(nx_compose_exec curl -s -m 8 -o /dev/null -w '%{http_code}' "http://localhost:8081$p" 2>/dev/null || echo 000)"
  case "$code" in 200|401|403) METRICS_PATH="$p"; break ;; esac
done
if [[ -z "$METRICS_PATH" ]]; then
  created=""
  for typeId in "metrics" "nexus:metrics"; do   # typeId differs across NX3 versions
    body="$(jq -n --arg t "$typeId" '{typeId: $t, notes: "Prometheus scrape (monitoring/scripts/10-enable-nexus-metrics.sh)"}')"
    if nx_api_rc POST "/capabilities" "$body" | head -1 | grep -qE "^(200|201)"; then
      created="$typeId"; break
    fi
  done
  [[ -n "$created" ]] || die "no built-in metrics endpoint and capability enable failed (tried typeIds: metrics, nexus:metrics)"
  log_ok "metrics capability enabled (typeId=$created)"
  METRICS_PATH="/service/metrics/prometheus"
else
  log_ok "metrics endpoint built in at $METRICS_PATH (Nexus >= 3.96 - no capability needed)"
fi

# --- 2. zero-privilege role ---------------------------------------------------
role_body="$(jq -n '{
  id: "monitoring-metrics",
  name: "Monitoring metrics reader",
  description: "Zero-privilege role; existence of an authenticated session is all /service/metrics requires. Managed by monitoring/scripts/10-enable-nexus-metrics.sh",
  privileges: [],
  roles: []
}')"
code="$(nx_api_rc POST "/security/roles" "$role_body" | head -1)"
case "$code" in
  200|201) log_ok "role monitoring-metrics created" ;;
  409)     log_ok "role monitoring-metrics exists" ;;
  *)       nx_api PUT "/security/roles/monitoring-metrics" "$role_body" >/dev/null; log_ok "role monitoring-metrics updated" ;;
esac

# --- 3. metrics user ----------------------------------------------------------
user_body="$(jq -n --arg u "$METRICS_USER" --arg p "$METRICS_PW" --arg d "$PLATFORM_DOMAIN" '{
  userId: $u, firstName: "Prometheus", lastName: "Scrape",
  email: ($u + "@" + $d), password: $p, status: "active",
  roles: ["monitoring-metrics"]
}')"
if nx_api GET "/security/users?userId=$METRICS_USER" | jq -e --arg u "$METRICS_USER" '.[] | select(.userId==$u)' >/dev/null 2>&1; then
  nx_api PUT "/security/users/$METRICS_USER" "$user_body" >/dev/null
  log_ok "user $METRICS_USER exists — password/roles refreshed"
else
  nx_api POST "/security/users" "$user_body" >/dev/null
  log_ok "user $METRICS_USER created"
fi

# --- 4. end-to-end validation -------------------------------------------------
code="$(nx_compose_exec curl -sS -m 10 -o /dev/null -w '%{http_code}' \
        -u "$METRICS_USER:$METRICS_PW" "http://localhost:8081$METRICS_PATH" || echo 000)"
[[ "$code" == "200" ]] || die "metrics endpoint returned HTTP $code for $METRICS_USER — capability or password mismatch"
log_ok "Nexus metrics endpoint validated (HTTP 200 as $METRICS_USER)"
log_info "Prometheus job 'nexus' (nexus:8081) will go UP on next reload: docker compose exec prometheus kill -HUP 1"
