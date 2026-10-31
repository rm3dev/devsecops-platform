#!/usr/bin/env bash
# =============================================================================
# 50-gitops-repository.sh — Phase 8: fill platform/gitops-repository with the
# real content (chart, sample app, clusters/) and provision CI write access.
#
# The project itself was created + skeleton-seeded in Phase 4 (30-/40-). This
# script SYNCS the platform tree gitops-repository/ into it:
#   * helm-charts/, clusters/, scripts/, README.md, CODEOWNERS  → always
#     replaced (platform-owned; clusters/*/environment.yaml is templated —
#     ${PLATFORM_DOMAIN} substituted at push time)
#   * applications/<svc>/ → added when NEW; an app that already exists in the
#     repo is left UNTOUCHED (its overlays carry CI-committed digests and its
#     values are team-owned — overwriting them would roll back deployments)
#
# Access wiring (CE-compatible, D-19; Phase 4 pre-created both PATs — this
# script re-verifies/repairs them and adds the ArgoCD reader token):
#   * jenkins-ci → Maintainer of THIS project only (protected main allows
#     Maintainer pushes; the account stays Developer everywhere else)
#   * PAT 'gitops-write' (write_repository) for jenkins-ci →
#     secrets/gitlab-jenkins.env GITOPS_REPO_TOKEN — consumed by Jenkins
#     (gitops-commit-token credential → updateGitOps/promoteDigest pushes).
#   * PAT 'argocd-read' (read_repository) for the 'argocd' GitLab user →
#     ARGOCD_GIT_TOKEN — consumed ONLY by ArgoCD repo-server (pull). Write
#     and read access are separate identities (least privilege).
#   * Rotation: an existing PAT is revoked + recreated ONLY when the stored
#     token is still the placeholder.
#
# Idempotent. Run AFTER 30-/40- and BEFORE kubernetes/argocd/install-argocd.sh
# (which validates the token with `argocd repo add`).
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gitlab-api.sh"
load_env; load_gitlab_secrets
require_cmd jq envsubst

PROJECT="platform/gitops-repository"
GIT_BIN=/opt/gitlab/embedded/bin/git
GL_JENKINS_ENV="$ROOT_DIR/secrets/gitlab-jenkins.env"

wait_for_gitlab
PID="$(gl_api GET "/projects/$(uri_encode "$PROJECT")" | jq -r '.id // empty')"
[[ -n "$PID" ]] || die "project ${PROJECT} missing — run gitlab/scripts/30-projects.sh + 40-seed-repositories.sh first"

# --- 1. jenkins-ci → Maintainer of this project ---------------------------------
JCI_ID="$(gl_api GET "/users?username=jenkins-ci" | jq -r '.[0].id // empty')"
[[ -n "$JCI_ID" ]] || die "user jenkins-ci missing — run gitlab/scripts/20-users-groups.sh"
MEMBER_LEVEL="$(gl_api GET "/projects/${PID}/members/all/${JCI_ID}" | jq -r '.access_level // empty')"
if [[ "$MEMBER_LEVEL" == "40" || "$MEMBER_LEVEL" == "50" ]]; then
  log_ok "jenkins-ci already Maintainer+ on ${PROJECT} (level ${MEMBER_LEVEL})"
else
  if [[ -n "$MEMBER_LEVEL" ]]; then
    gl_api PUT "/projects/${PID}/members/${JCI_ID}" "{\"access_level\":40}" | jq -e '.access_level >= 40' >/dev/null
  else
    gl_api POST "/projects/${PID}/members" "{\"user_id\":${JCI_ID},\"access_level\":40}" | jq -e '.access_level >= 40' >/dev/null
  fi
  log_ok "jenkins-ci granted Maintainer on ${PROJECT} (protected-main push rights)"
fi

# --- 2. PAT 'gitops-write' → GITOPS_REPO_TOKEN -----------------------------------
CURRENT_TOKEN="$(grep -E '^GITOPS_REPO_TOKEN=' "$GL_JENKINS_ENV" 2>/dev/null | cut -d= -f2- || true)"
EXISTING="$(gl_api GET "/users/${JCI_ID}/personal_access_tokens?name=gitops-write" | jq -r '.[0] | select(.revoked==false and .active==true) | .id // empty' 2>/dev/null || true)"
if [[ -n "$EXISTING" && -n "$CURRENT_TOKEN" && "$CURRENT_TOKEN" != "SET_IN_PHASE_8" ]]; then
  log_ok "PAT gitops-write exists and GITOPS_REPO_TOKEN is set — keeping both"
else
  [[ -n "$EXISTING" ]] && { gl_api DELETE "/personal_access_tokens/${EXISTING}" >/dev/null; log_warn "revoked stale PAT gitops-write (stored token was missing/placeholder)"; }
  EXPIRES="$(date -d '+365 days' +%F 2>/dev/null || date -v+365d +%F)"
  NEW_TOKEN="$(gl_api POST "/users/${JCI_ID}/personal_access_tokens" \
    "$(jq -n --arg exp "$EXPIRES" '{name:"gitops-write", scopes:["write_repository"], expires_at:$exp}')" | jq -r '.token // empty')"
  [[ -n "$NEW_TOKEN" ]] || die "failed to create PAT gitops-write for jenkins-ci"
  if grep -qE '^GITOPS_REPO_TOKEN=' "$GL_JENKINS_ENV" 2>/dev/null; then
    sed -i "s|^GITOPS_REPO_TOKEN=.*|GITOPS_REPO_TOKEN=${NEW_TOKEN}|" "$GL_JENKINS_ENV"
  else
    echo "GITOPS_REPO_TOKEN=${NEW_TOKEN}" >> "$GL_JENKINS_ENV"
  fi
  chmod 600 "$GL_JENKINS_ENV"
  log_ok "PAT gitops-write created (expires ${EXPIRES}) → secrets/gitlab-jenkins.env GITOPS_REPO_TOKEN"
  TOKEN_CHANGED=1
fi

# --- 2b. PAT 'argocd-read' for the argocd GitLab user (repo-server pull-only) ---
ARGOCD_USER_ID="$(gl_api GET "/users?username=argocd" | jq -r '.[0].id // empty')"
[[ -n "$ARGOCD_USER_ID" ]] || die "user 'argocd' missing — run gitlab/scripts/20-users-groups.sh"
CURRENT_ARGO_TOKEN="$(grep -E '^ARGOCD_GIT_TOKEN=' "$GL_JENKINS_ENV" 2>/dev/null | cut -d= -f2- || true)"
EXISTING_ARGO="$(gl_api GET "/users/${ARGOCD_USER_ID}/personal_access_tokens?name=argocd-read" | jq -r '.[0] | select(.revoked==false and .active==true) | .id // empty' 2>/dev/null || true)"
if [[ -n "$EXISTING_ARGO" && -n "$CURRENT_ARGO_TOKEN" && "$CURRENT_ARGO_TOKEN" != "SET_IN_PHASE_8" ]]; then
  log_ok "PAT argocd-read exists and ARGOCD_GIT_TOKEN is set — keeping both"
else
  [[ -n "$EXISTING_ARGO" ]] && { gl_api DELETE "/personal_access_tokens/${EXISTING_ARGO}" >/dev/null; log_warn "revoked stale PAT argocd-read"; }
  EXPIRES="$(date -d '+365 days' +%F 2>/dev/null || date -v+365d +%F)"
  NEW_ARGO_TOKEN="$(gl_api POST "/users/${ARGOCD_USER_ID}/personal_access_tokens" \
    "$(jq -n --arg exp "$EXPIRES" '{name:"argocd-read", scopes:["read_repository"], expires_at:$exp}')" | jq -r '.token // empty')"
  [[ -n "$NEW_ARGO_TOKEN" ]] || die "failed to create PAT argocd-read for user 'argocd'"
  if grep -qE '^ARGOCD_GIT_TOKEN=' "$GL_JENKINS_ENV" 2>/dev/null; then
    sed -i "s|^ARGOCD_GIT_TOKEN=.*|ARGOCD_GIT_TOKEN=${NEW_ARGO_TOKEN}|" "$GL_JENKINS_ENV"
  else
    echo "ARGOCD_GIT_TOKEN=${NEW_ARGO_TOKEN}" >> "$GL_JENKINS_ENV"
  fi
  chmod 600 "$GL_JENKINS_ENV"
  log_ok "PAT argocd-read created (expires ${EXPIRES}) → secrets/gitlab-jenkins.env ARGOCD_GIT_TOKEN"
  TOKEN_CHANGED=1
fi
# the argocd user needs at least Reporter on the project to read it
ARGO_MEMBER_LEVEL="$(gl_api GET "/projects/${PID}/members/all/${ARGOCD_USER_ID}" | jq -r '.access_level // empty')"
if [[ -z "$ARGO_MEMBER_LEVEL" || "$ARGO_MEMBER_LEVEL" -lt 20 ]]; then
  if [[ -n "$ARGO_MEMBER_LEVEL" ]]; then
    gl_api PUT "/projects/${PID}/members/${ARGOCD_USER_ID}" '{"access_level":20}' >/dev/null
  else
    gl_api POST "/projects/${PID}/members" "{\"user_id\":${ARGOCD_USER_ID},\"access_level\":20}" >/dev/null
  fi
  log_ok "argocd user granted Reporter on ${PROJECT}"
else
  log_ok "argocd user already Reporter+ on ${PROJECT} (level ${ARGO_MEMBER_LEVEL})"
fi

# --- 3. content sync ---------------------------------------------------------------
STAGING="$(mktemp -d)"; trap 'rm -rf "$STAGING"' EXIT
cp -r "$ROOT_DIR/gitops-repository/." "$STAGING/"
# template substitution: only clusters/*/environment.yaml carries ${PLATFORM_DOMAIN}
while IFS= read -r f; do
  PLATFORM_DOMAIN="$PLATFORM_DOMAIN" envsubst '${PLATFORM_DOMAIN}' < "$f" > "$f.sub" && mv "$f.sub" "$f"
done < <(find "$STAGING/clusters" -name '*.yaml' -type f)

SEED_DIR="/tmp/sync-gitops-repository"
gl_compose_exec rm -rf "$SEED_DIR"
gl_compose_exec mkdir -p "$SEED_DIR"
( cd "$ROOT_DIR" && docker compose -f docker-compose.yml cp "${STAGING}/." "gitlab:${SEED_DIR}/" >/dev/null ) \
  || die "docker compose cp into gitlab container failed"

if ! ( cd "$ROOT_DIR" && docker compose -f docker-compose.yml exec -T \
    -e GL_TOKEN="${GITLAB_ROOT_TOKEN}" -e GL_PATH="${PROJECT}" -e SYNC_DIR="${SEED_DIR}" -e GIT_BIN="${GIT_BIN}" \
    gitlab sh -eu -c '
      WORK=/tmp/gitops-sync
      rm -rf "$WORK"
      "$GIT_BIN" -c safe.directory="*" clone -q "http://oauth2:${GL_TOKEN}@localhost/${GL_PATH}.git" "$WORK"
      cd "$WORK"
      "$GIT_BIN" -c safe.directory="*" config user.name  "DevSecOps Platform Bootstrap"
      "$GIT_BIN" -c safe.directory="*" config user.email "devsecops@localhost"

      # platform-owned paths: always replaced
      rm -rf helm-charts clusters scripts README.md CODEOWNERS
      for item in helm-charts clusters scripts README.md CODEOWNERS; do
        [ -e "$SYNC_DIR/$item" ] && cp -a "$SYNC_DIR/$item" .
      done

      # applications/: add new apps only; never touch existing (CI-committed digests)
      mkdir -p applications
      for app in "$SYNC_DIR"/applications/*/; do
        [ -d "$app" ] || continue
        name="$(basename "$app")"
        if [ -d "applications/$name" ]; then
          echo "[sync] applications/$name exists — preserved (team/CI owned)"
        else
          cp -a "$app" "applications/$name"
          echo "[sync] applications/$name added"
        fi
      done

      "$GIT_BIN" -c safe.directory="*" add -A
      if "$GIT_BIN" -c safe.directory="*" diff --cached --quiet; then
        echo "[sync] no content changes"
      else
        "$GIT_BIN" -c safe.directory="*" commit -q -m "chore(platform): sync gitops-repository content (chart/clusters/scripts) — Phase 8"
        "$GIT_BIN" -c safe.directory="*" push -q origin main
        echo "[sync] pushed to main"
      fi
      rm -rf "$WORK"
    ' ); then
  gl_compose_exec rm -rf "$SEED_DIR" || true
  die "gitops-repository content sync failed"
fi
gl_compose_exec rm -rf "$SEED_DIR" || true
log_ok "${PROJECT}: content synced (chart + clusters + scripts; existing applications preserved)"

if [[ "${TOKEN_CHANGED:-0}" == "1" ]]; then
  log_warn "GITOPS_REPO_TOKEN changed — re-run kubernetes/argocd/install-argocd.sh (it re-registers the repo credentials) and restart jenkins (docker compose up -d jenkins)"
fi
log_ok "gitops-repository ready for ArgoCD + CI"
