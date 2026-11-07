#!/usr/bin/env bash
# =============================================================================
# 56-teams-read-token.sh — create a read_repository-only deploy token scoped
# to the teams group. Jenkins uses it only for HTTP checkout of private app
# repositories; GitLab API discovery continues to use the separate PAT.
#
# Safe to re-run: preserves a complete existing credential pair; refuses to
# mint an orphan if exactly one value is present.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gitlab-api.sh"
load_env; load_gitlab_secrets
require_cmd jq

SECRET_FILE="$ROOT_DIR/secrets/gitlab-jenkins.env"
if [[ -n "${GITLAB_TEAMS_READ_USER:-}" && -n "${GITLAB_TEAMS_READ_TOKEN:-}" \
      && "${GITLAB_TEAMS_READ_USER}" != SET_IN_PHASE_* \
      && "${GITLAB_TEAMS_READ_TOKEN}" != SET_IN_PHASE_* ]]; then
  log_ok "teams-group read-only checkout token already provisioned; unchanged"
  exit 0
fi
if [[ -n "${GITLAB_TEAMS_READ_USER:-}" || -n "${GITLAB_TEAMS_READ_TOKEN:-}" ]]; then
  die "only one of GITLAB_TEAMS_READ_USER/TOKEN is present; inspect ${SECRET_FILE} before retrying"
fi

GROUP_ID="$(gl_api GET "/groups/teams" | jq -r '.id // empty')"
[[ -n "$GROUP_ID" ]] || die "GitLab group 'teams' not found — run gitlab/scripts/20-users-groups.sh first"
EXPIRES="$(date -d '+364 days' +%F 2>/dev/null || date -v+364d +%F)"
PAYLOAD="$(jq -n --arg name "jenkins-teams-read" --arg expires "$EXPIRES" \
  '{name:$name, scopes:["read_repository"], expires_at:$expires}')"
RESPONSE="$(gl_api POST "/groups/${GROUP_ID}/deploy_tokens" "$PAYLOAD")"
DEPLOY_USER="$(jq -r '.username // empty' <<<"$RESPONSE")"
DEPLOY_TOKEN="$(jq -r '.token // empty' <<<"$RESPONSE")"
[[ -n "$DEPLOY_USER" && -n "$DEPLOY_TOKEN" ]] \
  || die "GitLab did not return deploy-token credentials; response was not saved"

append_secret "$SECRET_FILE" "GITLAB_TEAMS_READ_USER=${DEPLOY_USER}"
append_secret "$SECRET_FILE" "GITLAB_TEAMS_READ_TOKEN=${DEPLOY_TOKEN}"
chmod 600 "$SECRET_FILE"
unset DEPLOY_TOKEN RESPONSE PAYLOAD
log_ok "teams-group read_repository deploy token saved to secrets/gitlab-jenkins.env (expires ${EXPIRES})"
