#!/usr/bin/env bash
# =============================================================================
# 55-library-read-token.sh — create a project-scoped, read-only deploy token
# for Jenkins' global shared-library checkout.
#
# Jenkins global-library retrieval runs in a Pipeline context and cannot use
# SYSTEM-scoped credentials (JENKINS-45843). Do NOT broaden the api-scoped
# jenkins-ci PAT to GLOBAL. This deploy token is restricted to this one project
# and to read_repository; its username/token are stored only in the local,
# gitignored secrets/gitlab-jenkins.env file.
#
# Safe to re-run: if both secret values are already present, it leaves them
# unchanged. If one is missing, it stops rather than minting an orphan token.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gitlab-api.sh"
load_env; load_gitlab_secrets
require_cmd jq

SECRET_FILE="$ROOT_DIR/secrets/gitlab-jenkins.env"
PROJECT_PATH="platform/devsecops-shared-library"

if [[ -n "${GITLAB_LIBRARY_READ_USER:-}" && -n "${GITLAB_LIBRARY_READ_TOKEN:-}" \
      && "${GITLAB_LIBRARY_READ_USER}" != SET_IN_PHASE_* \
      && "${GITLAB_LIBRARY_READ_TOKEN}" != SET_IN_PHASE_* ]]; then
  log_ok "project-scoped shared-library read token already provisioned; unchanged"
  exit 0
fi
if [[ -n "${GITLAB_LIBRARY_READ_USER:-}" || -n "${GITLAB_LIBRARY_READ_TOKEN:-}" ]]; then
  die "only one of GITLAB_LIBRARY_READ_USER/TOKEN is present; inspect ${SECRET_FILE} before retrying"
fi

PROJECT_ID="$(gl_api GET "/projects/$(uri_encode "$PROJECT_PATH")" | jq -r '.id // empty')"
[[ -n "$PROJECT_ID" ]] || die "GitLab project ${PROJECT_PATH} not found"

EXPIRES="$(date -d '+364 days' +%F 2>/dev/null || date -v+364d +%F)"
PAYLOAD="$(jq -n --arg name "jenkins-shared-library-read" --arg expires "$EXPIRES" \
  '{name:$name, scopes:["read_repository"], expires_at:$expires}')"
RESPONSE="$(gl_api POST "/projects/${PROJECT_ID}/deploy_tokens" "$PAYLOAD")"
DEPLOY_USER="$(jq -r '.username // empty' <<<"$RESPONSE")"
DEPLOY_TOKEN="$(jq -r '.token // empty' <<<"$RESPONSE")"
[[ -n "$DEPLOY_USER" && -n "$DEPLOY_TOKEN" ]] \
  || die "GitLab did not return deploy-token credentials; response was not saved"

append_secret "$SECRET_FILE" "GITLAB_LIBRARY_READ_USER=${DEPLOY_USER}"
append_secret "$SECRET_FILE" "GITLAB_LIBRARY_READ_TOKEN=${DEPLOY_TOKEN}"
chmod 600 "$SECRET_FILE"
unset DEPLOY_TOKEN RESPONSE PAYLOAD
log_ok "project-only read_repository deploy token saved to secrets/gitlab-jenkins.env (expires ${EXPIRES})"
