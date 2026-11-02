#!/usr/bin/env bash
# =============================================================================
# 10-admin-bootstrap.sh — SonarQube admin + CI token + server settings.
#
#  * replaces the default admin/admin password (stored in secrets/sonar.env)
#  * hardening: force authentication (no anonymous browsing), serverBaseURL,
#    project provisioning stays admin-only
#  * creates service user 'jenkins' with ONLY 'Execute Analysis' permission
#  * generates its analysis token → SONARQUBE_TOKEN in secrets/sonar-jenkins.env
#    (consumed by JCasC credential 'sonarqube-admin-token' after recreate)
#  * best-effort global webhook → http://jenkins:8080/sonarqube-webhook/ with
#    HMAC secret; on editions without webhook support the pipeline falls back
#    to scanner-side sonar.qualitygate.wait (D-20) — degradation is logged, not fatal
#
# Idempotent: validates stored credentials/tokens before recreating anything.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sonar-api.sh"
load_env; load_sonar_secrets
require_cmd jq

wait_for_sonar

# ------------------------------------------------------- 1. admin password ---
if [[ -n "${SONAR_ADMIN_PASSWORD:-}" ]] && sq_validate_auth "admin:${SONAR_ADMIN_PASSWORD}"; then
  log_ok "stored SONAR_ADMIN_PASSWORD is valid"
else
  NEW_ADMIN_PASSWORD="$(gen_secret)"
  if sq_validate_auth "admin:admin"; then
    log_info "changing default admin password…"
    sq_api POST "/users/change_password" "login=admin&previousPassword=admin&password=${NEW_ADMIN_PASSWORD}" >/dev/null \
      || die "admin password change failed"
  else
    # neither stored password nor factory default works (externally rotated)
    die "stored admin password rejected and factory admin:admin is not active.
Recover by restarting with -Dsonar.forceAuthentication=false and resetting the
password through the UI, or restore a known password in the SonarQube DB, then re-run."
  fi
  append_secret "$ROOT_DIR/secrets/sonar.env" "SONAR_ADMIN_PASSWORD=${NEW_ADMIN_PASSWORD}"
  load_sonar_secrets
  sq_validate_auth "admin:${SONAR_ADMIN_PASSWORD}" || die "new admin password does not validate"
  log_ok "admin password set → secrets/sonar.env (SONAR_ADMIN_PASSWORD)"
fi

# ------------------------------------------------------- 2. server settings ---
sq_api POST "/settings/set" "key=sonar.forceAuthentication&value=true" >/dev/null \
  && log_ok "sonar.forceAuthentication=true (anonymous access disabled)" \
  || log_warn "could not enforce authentication (check admin rights)"
if [[ -n "${SONAR_PUBLIC_URL:-}" ]]; then
  sq_api POST "/settings/set" "key=sonar.core.serverBaseURL&value=${SONAR_PUBLIC_URL}" >/dev/null \
    && log_ok "serverBaseURL=${SONAR_PUBLIC_URL}" || log_warn "serverBaseURL not set"
fi
# Project creation (provisioning) restricted to admins — belt & braces, this is
# already the default; remove any accidental grant to sonar-users.
sq_api POST "/permissions/remove_group" "group=sonar-users&permission=provisioning" >/dev/null 2>&1 || true

# --------------------------------------------------- 3. jenkins CI service ---
USER_EXISTS="$(sq_api GET "/users/search?q=jenkins&ps=500" | jq -r '[.users[]? | select(.login=="jenkins")] | length')"
if [[ "$USER_EXISTS" == "0" ]]; then
  CI_PASSWORD="$(gen_secret)"
  sq_api POST "/users/create" "login=jenkins&name=Jenkins CI&password=${CI_PASSWORD}&local=true" >/dev/null \
    || die "could not create user 'jenkins'"
  append_secret "$ROOT_DIR/secrets/sonar-users.env" "SONAR_JENKINS_USER_PASSWORD=${CI_PASSWORD}"
  log_ok "service user 'jenkins' created (initial password → secrets/sonar-users.env, break-glass only)"
else
  log_ok "service user 'jenkins' exists"
fi
sq_api POST "/permissions/add_user" "login=jenkins&permission=scan" >/dev/null 2>&1 \
  && log_info "'Execute Analysis' permission ensured for jenkins" \
  || log_warn "could not grant scan permission (may already be set)"

# Analysis token (stored value reused while valid; otherwise regenerate with a
# unique name so revoked tokens can never shadow the new one).
if [[ -n "${SONARQUBE_TOKEN:-}" && "$SONARQUBE_TOKEN" != "SET_IN_PHASE_5" ]] \
   && sq_validate_auth "jenkins:${SONARQUBE_TOKEN}"; then
  log_ok "stored SONARQUBE_TOKEN is valid"
else
  SUFFIX=0
  while :; do
    TOKEN_NAME="platform-jenkins$([[ $SUFFIX -gt 0 ]] && echo "-${SUFFIX}")"
    RESP="$(sq_api_rc POST "/user_tokens/generate" "name=${TOKEN_NAME}&login=jenkins&type=USER_TOKEN")"
    CODE="$(echo "$RESP" | head -1)"; BODY="$(echo "$RESP" | tail -n +2)"
    if [[ "$CODE" == "200" ]]; then
      TOKEN_VALUE="$(echo "$BODY" | jq -r '.token')"
      [[ -n "$TOKEN_VALUE" && "$TOKEN_VALUE" != "null" ]] || die "token generate returned no value"
      append_secret "$ROOT_DIR/secrets/sonar-jenkins.env" "SONARQUBE_TOKEN=${TOKEN_VALUE}"
      log_ok "analysis token '${TOKEN_NAME}' created → secrets/sonar-jenkins.env"
      break
    elif [[ "$CODE" == "400" && "$BODY" == *"already exists"* ]]; then
      sq_api POST "/user_tokens/revoke" "name=${TOKEN_NAME}&login=jenkins" >/dev/null 2>&1 || true
      SUFFIX=$((SUFFIX+1)); continue
    else
      die "user_tokens/generate failed (HTTP ${CODE}): ${BODY}"
    fi
  done
fi

# -------------------------------------------------------- 4. global webhook ---
# Jenkins sonar plugin endpoint; HMAC secret shared via SONAR_WEBHOOK_TOKEN.
: "${SONAR_WEBHOOK_TOKEN:?SONAR_WEBHOOK_TOKEN missing in secrets/sonar-jenkins.env}"
WH_URL="http://jenkins:8080/sonarqube-webhook/"
for wh_id in $(sq_api GET "/webhooks/list" | jq -r --arg u "$WH_URL" '.webhooks[]? | select(.url==$u) | .key'); do
  sq_api POST "/webhooks/delete" "webhookKey=${wh_id}" >/dev/null && log_info "removed stale webhook ${wh_id}"
done
RESP="$(sq_api_rc POST "/webhooks/create" "name=jenkins&url=${WH_URL}&secret=${SONAR_WEBHOOK_TOKEN}")"
CODE="$(echo "$RESP" | head -1)"
if [[ "$CODE" == "200" ]]; then
  log_ok "global webhook → ${WH_URL} created (HMAC secret = SONAR_WEBHOOK_TOKEN)"
else
  log_warn "global webhook creation returned HTTP ${CODE} — webhooks unsupported on this edition/tier."
  log_warn "Quality-gate enforcement falls back to scanner-side sonar.qualitygate.wait=true (D-20) — pipelines remain gated; no action needed."
fi

# -------------------------------------------------------- 5. connectivity -----
CODE="$(sq_compose_exec curl -sS -m 10 -o /dev/null -w '%{http_code}' http://jenkins:8080/login || echo 000)"
[[ "$CODE" == "200" ]] && log_ok "SonarQube→Jenkins internal reachability verified (HTTP 200)" \
  || log_warn "SonarQube cannot reach http://jenkins:8080 (HTTP ${CODE}) — webhook deliveries will fail until Jenkins is up"

log_ok "SonarQube admin bootstrap complete"
