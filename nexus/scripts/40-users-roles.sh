#!/usr/bin/env bash
# =============================================================================
# 40-users-roles.sh — least-privilege CI account for artifact deployment.
#
# role 'jenkins-deploy':
#   read/browse on every repository (pull deps + images)
#   add/edit on HOSTED repositories only (publish artifacts + push images)
#   NO delete anywhere; NO security/admin privileges
# user 'jenkins-ci' (password → secrets/nexus-jenkins.env NEXUS_DEPLOY_PASSWORD,
#   consumed by JCasC credential 'nexus-deploy' after Jenkins recreate)
#
# Privilege IDs are enumerated per concrete repository (Nexus matches explicit
# IDs; wildcard strings are not stored reliably via REST) — regenerated from
# the live repository list on every run, so new repos are picked up when the
# role is updated.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/nexus-api.sh"
load_env; load_nexus_secrets
require_cmd jq

: "${NEXUS_ADMIN_PASSWORD:?run 10-admin-bootstrap.sh first}"

# Repos Jenkins may PUBLISH to (hosted); everything else is read-only.
PUBLISH_FORMATS=("maven2:maven-releases" "maven2:maven-snapshots" "npm:npm-hosted" \
                 "pypi:pypi-hosted" "nuget:nuget-hosted" "raw:raw-hosted" "docker:docker-hosted")

LIVE_REPOS="$(nx_api GET "/repositories" | jq -r '.[] | "\(.format) \(.name)"')"

PRIVILEGES='["nx-search-read"]'
# read + browse on ALL live repositories (format + name from the API)
while read -r fmt name; do
  PRIVILEGES="$(jq -c --arg p1 "nx-repository-view-${fmt}-${name}-read" \
                    --arg p2 "nx-repository-view-${fmt}-${name}-browse" \
                    '. + [$p1, $p2]' <<< "$PRIVILEGES")"
done <<< "$LIVE_REPOS"
# add + edit ONLY on publish targets that actually exist — Nexus auto-creates
# nx-repository-view-* privileges per repository, so naming a not-yet-created
# repo 400s the whole role ("Privilege ... not found"). Re-run after step 30
# completes and the role UPDATE path picks the late additions up.
for entry in "${PUBLISH_FORMATS[@]}"; do
  fmt="${entry%%:*}"; name="${entry##*:}"
  if grep -qxF "${fmt} ${name}" <<< "$LIVE_REPOS"; then
    PRIVILEGES="$(jq -c --arg p1 "nx-repository-view-${fmt}-${name}-add" \
                      --arg p2 "nx-repository-view-${fmt}-${name}-edit" \
                      '. + [$p1, $p2]' <<< "$PRIVILEGES")"
  else
    log_warn "publish target '${name}' (${fmt}) not present yet — add/edit privileges skipped (re-run after step 30)"
  fi
done
log_info "role privilege set: $(jq 'length' <<< "$PRIVILEGES") privileges"

ROLE_BODY="$(jq -n --argjson p "$PRIVILEGES" '{
  id: "jenkins-deploy",
  name: "Jenkins CI deploy",
  description: "Read everywhere; publish to hosted repos; no delete/admin. Managed by nexus/scripts/40-users-roles.sh",
  privileges: $p,
  roles: []
}')"
ROLE_EXISTS="$(nx_api GET "/security/roles" | jq -r '.[] | select(.id=="jenkins-deploy") | .id')"
if [[ -n "$ROLE_EXISTS" ]]; then
  RESP="$(nx_api_rc PUT "/security/roles/jenkins-deploy" "$ROLE_BODY")"; CODE="${RESP%%$'\n'*}"
  [[ "$CODE" == "200" || "$CODE" == "204" ]] && log_ok "role 'jenkins-deploy' updated" \
    || die "role update failed (HTTP ${CODE}) — Nexus said: $(tail -n +2 <<<"$RESP" | head -c 400)"
else
  RESP="$(nx_api_rc POST "/security/roles" "$ROLE_BODY")"; CODE="${RESP%%$'\n'*}"
  [[ "$CODE" == "200" || "$CODE" == "201" ]] && log_ok "role 'jenkins-deploy' created" \
    || die "role creation failed (HTTP ${CODE}) — Nexus said: $(tail -n +2 <<<"$RESP" | head -c 400)"
fi

# ---------------------------------------------------------------- user ------
DEPLOY_PASSWORD="${NEXUS_DEPLOY_PASSWORD:-SET_IN_PHASE_5}"
USER_EXISTS="$(nx_api GET "/security/users?userId=jenkins-ci&source=default" | jq -r '.[0].userId // empty')"
if [[ -z "$USER_EXISTS" ]]; then
  [[ "$DEPLOY_PASSWORD" == "SET_IN_PHASE_5" ]] && DEPLOY_PASSWORD="$(gen_secret)"
  USER_BODY="$(jq -n --arg pw "$DEPLOY_PASSWORD" --arg em "jenkins-ci@${PLATFORM_DOMAIN:-localhost}" '{
    userId: "jenkins-ci", firstName: "Jenkins", lastName: "CI",
    emailAddress: $em, password: $pw, status: "active", roles: ["jenkins-deploy"]
  }')"
  RESP="$(nx_api_rc POST "/security/users" "$USER_BODY")"; CODE="${RESP%%$'\n'*}"
  [[ "$CODE" == "200" || "$CODE" == "201" ]] && log_ok "user 'jenkins-ci' created" \
    || die "user creation failed (HTTP ${CODE}) — Nexus said: $(tail -n +2 <<<"$RESP" | head -c 400)"
  append_secret "$ROOT_DIR/secrets/nexus-jenkins.env" "NEXUS_DEPLOY_USER=jenkins-ci"
  append_secret "$ROOT_DIR/secrets/nexus-jenkins.env" "NEXUS_DEPLOY_PASSWORD=${DEPLOY_PASSWORD}"
else
  log_ok "user 'jenkins-ci' exists"
  if [[ "$DEPLOY_PASSWORD" == "SET_IN_PHASE_5" ]]; then
    DEPLOY_PASSWORD="$(gen_secret)"
    CODE="$(nx_compose_exec curl -sS -m 30 -o /tmp/nx-body -w '%{http_code}' -X PUT \
      -u "admin:${NEXUS_ADMIN_PASSWORD}" -H "Content-Type: text/plain" \
      --data "${DEPLOY_PASSWORD}" "${NEXUS_API}/security/users/jenkins-ci/change-password")"
    [[ "$CODE" == "204" || "$CODE" == "200" ]] || die "jenkins-ci password set failed (HTTP ${CODE})"
    append_secret "$ROOT_DIR/secrets/nexus-jenkins.env" "NEXUS_DEPLOY_PASSWORD=${DEPLOY_PASSWORD}"
    log_ok "jenkins-ci password rotated (was placeholder) → secrets/nexus-jenkins.env"
  fi
  # best-effort: keep role membership correct on pre-existing users
  USER_UPDATE_BODY="$(jq -n --arg em "jenkins-ci@${PLATFORM_DOMAIN:-localhost}" '{
    userId:"jenkins-ci", firstName:"Jenkins", lastName:"CI",
    emailAddress:$em, status:"active", roles:["jenkins-deploy"]}')"
  CODE="$(nx_api_rc PUT "/security/users/jenkins-ci" "$USER_UPDATE_BODY" | sed -n '1p')"
  [[ "$CODE" == "200" || "$CODE" == "204" ]] && log_info "jenkins-ci role membership re-asserted" \
    || log_warn "user-update endpoint returned HTTP ${CODE} — if roles diverge, adjust in UI: Security → Users → jenkins-ci"
fi

# validate the deploy credentials end-to-end (anonymous access is disabled)
load_nexus_secrets
CODE="$(nx_compose_exec curl -sS -m 10 -o /dev/null -w '%{http_code}' \
  -u "${NEXUS_DEPLOY_USER}:${NEXUS_DEPLOY_PASSWORD}" \
  "${NEXUS_API}/components?repository=maven-central" || echo 000)"
[[ "$CODE" == "200" ]] && log_ok "jenkins-ci credentials validated (read maven-central → HTTP 200)" \
  || die "jenkins-ci cannot read components (HTTP ${CODE}) — check role privileges"

log_ok "Nexus users/roles complete"
