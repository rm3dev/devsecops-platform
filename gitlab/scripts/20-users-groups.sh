#!/usr/bin/env bash
# =============================================================================
# 20-users-groups.sh — groups, service users and least-privilege PATs.
#
# Creates (idempotent):
#   groups : platform (private), teams (private)
#   users  : jenkins-ci  → CI service account (PATs: 'ci-api' [api,
#              read_repository] and 'gitops-write' [write_repository])
#            argocd       → GitOps reader (PAT provisioned in Phase 8)
#
# Secrets written: secrets/gitlab-users.env (user passwords),
#                  secrets/gitlab-jenkins.env (GITLAB_API_TOKEN,
#                  GITOPS_REPO_TOKEN — consumed by Jenkins JCasC credentials)
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gitlab-api.sh"
load_env; load_gitlab_secrets
require_cmd jq
# gen_secret() provided by scripts/lib/common.sh

# ---------------------------------------------------------------- groups ----
ensure_group() { # path
  local path="$1"
  local existing
  existing="$(gl_api GET "/groups/$(uri_encode "$path")" | jq -r '.id // empty')"
  if [[ -n "$existing" ]]; then
    log_ok "group '${path}' exists (id=${existing})"
  else
    gl_api POST /groups "$(jq -n --arg p "$path" '{name:$p, path:$p, visibility:"private"}')" \
      | jq -e '.id' >/dev/null || die "failed to create group '${path}'"
    log_info "group '${path}' created"
  fi
}
ensure_group platform
ensure_group teams

# ----------------------------------------------------------------- users ----
ensure_user() { # username, email → echoes user id
  local username="$1" email="$2"
  local id
  id="$(gl_api GET "/users?username=${username}" | jq -r '.[0].id // empty')"
  if [[ -z "$id" ]]; then
    local password; password="$(gen_secret)"
    id="$(gl_api POST /users "$(jq -n --arg u "$username" --arg e "$email" --arg p "$password" \
          '{username:$u, name:$u, email:$e, password:$p, can_create_group:false, projects_limit:0, skip_confirmation:true}')" \
          | jq -r '.id // empty')"
    [[ -n "$id" ]] || die "failed to create user '${username}'"
    append_secret "$ROOT_DIR/secrets/gitlab-users.env" "GITLAB_${username^^}_PASSWORD=${password}"
    log_info "user '${username}' created (id=${id}; password → secrets/gitlab-users.env)"
  else
    log_ok "user '${username}' exists (id=${id})"
  fi
  echo "$id"
}

JENKINS_CI_ID="$(ensure_user jenkins-ci  "jenkins-ci@${PLATFORM_DOMAIN}")"
ARGOCD_ID="$(ensure_user argocd          "argocd@${PLATFORM_DOMAIN}")"

# ------------------------------------------------------------------ PATs ----
token_valid() { # token → 0 if the token authenticates
  local token="$1"
  [[ -n "$token" && "$token" != SET_IN_PHASE_* ]] || return 1
  local code
  code="$(gl_compose_exec curl -sS -m 15 -o /dev/null -w '%{http_code}' \
          -H "PRIVATE-TOKEN: ${token}" "${GITLAB_API}/user" || echo 000)"
  [[ "$code" == "200" ]]
}

ensure_pat() { # user_id, token_name, scopes(csv), secret_file, secret_key
  local uid="$1" name="$2" scopes="$3" file="$4" key="$5"
  local current; current="$(grep -E "^${key}=" "$file" 2>/dev/null | cut -d= -f2- || true)"
  if token_valid "${current:-}"; then
    log_ok "PAT '${name}' already provisioned and valid (${key})"
    return
  fi
  local scopes_json; scopes_json="$(jq -cn --arg s "$scopes" '$s | split(",")')"
  # GitLab enforces max PAT lifetime of 365 days (expires_at must be strictly
  # before today+365) — 364 days keeps a margin and stays valid on re-runs.
  local expiry; expiry="$(date -d '+364 days' +%F 2>/dev/null || date -v+364d +%F)"
  local token
  token="$(gl_api POST "/users/${uid}/personal_access_tokens" \
    "$(jq -n --arg n "$name" --argjson s "$scopes_json" --arg exp "$expiry" \
       '{name:$n, scopes:$s, expires_at:$exp}')" | jq -r '.token // empty')"
  [[ -n "$token" ]] || die "failed to create PAT '${name}' for user id ${uid}"
  append_secret "$file" "${key}=${token}"
  log_info "PAT '${name}' created → ${key} in $(basename "$file") (scopes: ${scopes})"
}

ensure_pat "$JENKINS_CI_ID" "ci-api"       "api,read_repository" \
           "$ROOT_DIR/secrets/gitlab-jenkins.env" "GITLAB_API_TOKEN"
ensure_pat "$JENKINS_CI_ID" "gitops-write" "write_repository" \
           "$ROOT_DIR/secrets/gitlab-jenkins.env" "GITOPS_REPO_TOKEN"

# Webhook shared secret (bootstrap generated it; assert presence)
if ! grep -q '^GITLAB_WEBHOOK_TOKEN=' "$ROOT_DIR/secrets/gitlab-jenkins.env"; then
  append_secret "$ROOT_DIR/secrets/gitlab-jenkins.env" "GITLAB_WEBHOOK_TOKEN=$(gen_secret)"
  log_info "GITLAB_WEBHOOK_TOKEN generated"
fi

log_ok "users/groups/PATs ready. Jenkins picks the tokens up after: docker compose -f docker-compose.yml --profile core up -d jenkins"
