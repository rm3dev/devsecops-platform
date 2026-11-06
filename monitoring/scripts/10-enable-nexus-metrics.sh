#!/usr/bin/env bash
# =============================================================================
# 10-enable-nexus-metrics.sh — Nexus scrape target for Prometheus (Phase 10).
#
# Three idempotent actions:
#   1. enable the Nexus "metrics" capability (/service/metrics/prometheus)
#   2. create role  'monitoring-metrics' - least privilege: only the
#      built-in 'nx-metrics-all' (required by /service/rest/metrics/*)
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

# Prometheus runs as nobody (uid 65534, prom/prometheus image default) and reads
# this file via basic_auth.password_file through a :ro bind mount that preserves
# host ownership. bootstrap.sh writes it root:root 600 -> permission denied for
# the scrape. Hand ownership to uid 65534 (root keeps access; mode stays 600).
# The bind mount exposes the DIRECTORY as /etc/prometheus/secrets; if it is
# root-owned 700 (bootstrap hardening), nobody cannot traverse into it even
# when the file inside is already owned by 65534. Fix both.
PW_DIR="$(dirname "$PW_FILE")"
if [[ "$(stat -c '%u' "$PW_DIR" 2>/dev/null || echo x)" != "65534" ]]; then
  if chown 65534:65534 "$PW_DIR" 2>/dev/null; then
    chmod 700 "$PW_DIR"
    log_ok "secrets/prometheus dir -> uid 65534 mode 700 (traversable by prometheus)"
  else
    chmod 711 "$PW_DIR"
    log_warn "dir chown failed; mode 711 instead (traverse without listing)"
  fi
fi
if [[ "$(stat -c '%u' "$PW_FILE" 2>/dev/null || echo x)" != "65534" ]]; then
  if chown 65534:65534 "$PW_FILE" 2>/dev/null; then
    chmod 600 "$PW_FILE"
    log_ok "password file ownership -> uid 65534 (prometheus scrape user)"
  else
    chmod 644 "$PW_FILE"
    log_warn "chown to 65534 failed; relaxed file mode to 644 instead"
  fi
fi
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
    cap_resp="$(nx_api_rc POST "/capabilities" "$body" || true)"   # no |head: SIGPIPE trap
    if [[ "${cap_resp%%$'\n'*}" =~ ^(200|201) ]]; then
      created="$typeId"; break
    fi
  done
  [[ -n "$created" ]] || die "no built-in metrics endpoint and capability enable failed (tried typeIds: metrics, nexus:metrics)"
  log_ok "metrics capability enabled (typeId=$created)"
  METRICS_PATH="/service/metrics/prometheus"
else
  log_ok "metrics endpoint built in at $METRICS_PATH (Nexus >= 3.96 - no capability needed)"
fi

# --- 2. least-privilege role --------------------------------------------------
# /service/rest/metrics/* requires admin OR the built-in 'nx-metrics-all'
# privilege (Sonatype docs - same was true for the legacy /service/metrics/*).
# The old zero-privilege role authenticated fine but got 403 Forbidden.
role_body="$(jq -n '{
  id: "monitoring-metrics",
  name: "Monitoring metrics reader",
  description: "Least-privilege role for the Prometheus scrape: nx-metrics-all only. Managed by monitoring/scripts/10-enable-nexus-metrics.sh",
  privileges: ["nx-metrics-all"],
  roles: []
}')"
# No '| head -1' here: nx_api_rc prints code THEN runs a slow 'docker exec cat'
# for the body; head exits after line 1, cat dies of SIGPIPE (141), pipefail +
# set -e kill the script SILENTLY. Capture everything, split with expansion.
role_resp="$(nx_api_rc POST "/security/roles" "$role_body" || true)"
code="${role_resp%%$'\n'*}"
case "$code" in
  200|201) log_ok "role monitoring-metrics created" ;;
  *)
    put_resp="$(nx_api_rc PUT "/security/roles/monitoring-metrics" "$role_body" || true)"
    put_code="${put_resp%%$'\n'*}"
    case "$put_code" in
      200|204) log_ok "role monitoring-metrics updated (privilege nx-metrics-all)" ;;
      *) die "role monitoring-metrics update failed: HTTP $put_code - ${put_resp#*$'\n'}" ;;
    esac
    ;;
esac

# --- 3. metrics user ----------------------------------------------------------
# Nexus 3.96 renamed the field: emailAddress. The old name 'email' is silently
# ignored by 3.96 -> 400 "PARAMETER emailAddress must not be empty" -> the user
# was never created and every Prometheus scrape 401'd (then hit the auth rate
# limiter -> 429). Send BOTH spellings for cross-version compatibility, and
# 3.96 also requires 'source' ("default" = local realm) on PUT /security/users.
# CHECK the HTTP code: nx_api exits 0 even on 4xx (curl without -f), which is
# how this failure stayed invisible for four runs.
user_body="$(jq -n --arg u "$METRICS_USER" --arg p "$METRICS_PW" --arg d "$PLATFORM_DOMAIN" '{
  userId: $u, firstName: "Prometheus", lastName: "Scrape",
  email: ($u + "@" + $d), emailAddress: ($u + "@" + $d), password: $p, status: "active",
  source: "default",
  roles: ["monitoring-metrics"]
}')"
nx_user_call() { # METHOD PATH -> ok, or die showing code + response body
  local out code body
  out="$(nx_api_rc "$1" "$2" "$user_body")"
  code="${out%%$'\n'*}"; body="${out#*$'\n'}"
  case "$code" in
    200|201|204) return 0 ;;
    *) die "user '$METRICS_USER' $1 $2 failed: HTTP $code - $body" ;;
  esac
}
if nx_api GET "/security/users?userId=$METRICS_USER" | jq -e --arg u "$METRICS_USER" '.[] | select(.userId==$u)' >/dev/null 2>&1; then
  nx_user_call PUT "/security/users/$METRICS_USER"
  log_ok "user $METRICS_USER exists - password/roles refreshed"
else
  nx_user_call POST "/security/users"
  log_ok "user $METRICS_USER created"
fi

# --- 4. end-to-end validation -------------------------------------------------
code="$(nx_compose_exec curl -sS -m 10 -o /dev/null -w '%{http_code}' \
        -u "$METRICS_USER:$METRICS_PW" "http://localhost:8081$METRICS_PATH" || echo 000)"
[[ "$code" == "200" ]] || die "metrics endpoint returned HTTP $code for $METRICS_USER — capability or password mismatch"
log_ok "Nexus metrics endpoint validated (HTTP 200 as $METRICS_USER)"
log_info "Prometheus job 'nexus' (nexus:8081) will go UP on next reload: docker compose exec prometheus kill -HUP 1"
