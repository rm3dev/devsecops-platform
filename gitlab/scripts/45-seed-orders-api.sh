#!/usr/bin/env bash
# =============================================================================
# 45-seed-orders-api.sh — seed the SAMPLE MICROSERVICE for GETTING-STARTED §14.
#
#   1. GitLab subgroup  teams/orders            (the Jenkins org folder for
#      'teams/orders' is pre-seeded by JCasC — TEAMS list in 60-jobs.yaml —
#      and auto-discovers any project under it that has a Jenkinsfile)
#   2. GitLab project   teams/orders/orders-api (private, default branch main)
#   3. Seed the source  gitlab/seed/orders-api/ → main, using the exact
#      mechanics of 40-seed-repositories.sh: git runs INSIDE the gitlab
#      container against http://oauth2:…@localhost (no host git, no host TLS).
#      Skipped when main already exists (CI-owned history is never touched).
#   4. Repoint applications/orders-api in the LIVE gitops-repository from the
#      registry.devsecops.internal seed placeholder to registry.${PLATFORM_DOMAIN}
#      (values.yaml + 4 overlays + base/manifests.yaml). Required because:
#        - updateGitOps' pinDigest matches images[].name == the BUILT image
#          (registry.<domain>/<team>/<svc>) and hard-fails on a mismatch
#        - Kyverno pins/verifies only registry.${PLATFORM_DOMAIN}/*@sha256:*
#      Done via clone+sed+push inside the gitlab container (one commit).
#
# Idempotent: every step checks before acting; safe to re-run.
# After: Jenkins → teams → orders → "Scan Multibranch Pipeline Now" (or wait
# for the hourly org-folder scan) → first build of main starts automatically.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../scripts/lib/common.sh"
source "$HERE/lib/gitlab-api.sh"
load_env; load_gitlab_secrets
require_cmd jq

GIT_BIN=/opt/gitlab/embedded/bin/git
SEED_SRC="$ROOT_DIR/gitlab/seed/orders-api"
PROJECT_PATH="teams/orders/orders-api"
ENCODED="teams%2Forders%2Forders-api"
: "${GITLAB_ROOT_TOKEN:?GITLAB_ROOT_TOKEN missing (secrets/gitlab.env) — run gitlab/scripts/10-create-root-token.sh}"
: "${PLATFORM_DOMAIN:?PLATFORM_DOMAIN missing in .env}"

wait_for_gitlab

# --- 1. subgroup teams/orders ---------------------------------------------------
teams_id="$(gl_api GET "/groups?search=teams" | jq -r '[.[] | select(.full_path=="teams") | .id] | first // empty')"
[[ -n "$teams_id" ]] || die "group 'teams' not found — run gitlab/scripts/20-users-groups.sh first"
orders_id="$(gl_api GET "/groups/teams%2Forders" | jq -r '.id // empty')"
if [[ -z "$orders_id" ]]; then
  orders_id="$(gl_api POST "/groups" "$(jq -n --argjson p "$teams_id" \
    '{name:"orders", path:"orders", parent_id:$p, visibility:"private"}')" | jq -r '.id // empty')"
  [[ -n "$orders_id" ]] || die "could not create subgroup teams/orders"
  log_ok "subgroup teams/orders created (id=$orders_id)"
else
  log_ok "subgroup teams/orders exists (id=$orders_id)"
fi

# --- 2. project teams/orders/orders-api ------------------------------------------
pid="$(gl_api GET "/projects/$ENCODED" | jq -r '.id // empty')"
if [[ -z "$pid" ]]; then
  pid="$(gl_api POST "/projects" "$(jq -n --argjson ns "$orders_id" \
    '{name:"orders-api", path:"orders-api", namespace_id:$ns, visibility:"private",
      default_branch:"main", initialize_with_readme:false}')" | jq -r '.id // empty')"
  [[ -n "$pid" ]] || die "could not create project $PROJECT_PATH"
  log_ok "project $PROJECT_PATH created (id=$pid)"
else
  log_ok "project $PROJECT_PATH exists (id=$pid)"
fi

# --- 3. seed source → main (inside the gitlab container) --------------------------
if gl_api GET "/projects/$pid/repository/branches/main" | jq -e '.name == "main"' >/dev/null 2>&1; then
  log_ok "$PROJECT_PATH: main already seeded — not touching it (CI owns the history now)"
else
  [[ -d "$SEED_SRC" ]] || die "seed source missing: $SEED_SRC"
  seed_dir="/tmp/seed-orders-api"
  gl_compose_exec rm -rf "$seed_dir"
  gl_compose_exec mkdir -p "$seed_dir"
  ( cd "$ROOT_DIR" && docker compose -f docker-compose.yml cp "${SEED_SRC}/." "gitlab:${seed_dir}/" >/dev/null ) \
    || die "docker compose cp into the gitlab container failed"
  if ! ( cd "$ROOT_DIR" && docker compose -f docker-compose.yml exec -T \
      -e GL_TOKEN="$GITLAB_ROOT_TOKEN" -e GL_PATH="$PROJECT_PATH" \
      -e GL_SEED_DIR="$seed_dir" -e GIT_BIN="$GIT_BIN" \
      gitlab sh -eu -c '
        cd "$GL_SEED_DIR"
        "$GIT_BIN" -c safe.directory="*" init -b main . >/dev/null
        "$GIT_BIN" -c safe.directory="*" config user.name "DevSecOps Platform Bootstrap"
        "$GIT_BIN" -c safe.directory="*" config user.email "devsecops@localhost"
        "$GIT_BIN" -c safe.directory="*" add -A
        "$GIT_BIN" -c safe.directory="*" commit -m "feat: orders-api sample microservice (GETTING-STARTED 14)" >/dev/null
        "$GIT_BIN" -c safe.directory="*" remote add origin "http://oauth2:${GL_TOKEN}@localhost/${GL_PATH}.git"
        "$GIT_BIN" -c safe.directory="*" push -u origin main
      ' ); then
    gl_compose_exec rm -rf "$seed_dir" || true
    die "failed to push the seed to $PROJECT_PATH"
  fi
  gl_compose_exec rm -rf "$seed_dir" || true
  gl_api GET "/projects/$pid/repository/branches/main" | jq -e '.name == "main"' >/dev/null 2>&1 \
    && log_ok "$PROJECT_PATH: seeded (branch main)" \
    || die "$PROJECT_PATH: push reported success but main is missing"
fi

# --- 4. gitops-repository image refs → registry.${PLATFORM_DOMAIN} ----------------
if ( cd "$ROOT_DIR" && docker compose -f docker-compose.yml exec -T \
      -e GL_TOKEN="$GITLAB_ROOT_TOKEN" -e GIT_BIN="$GIT_BIN" -e DOMAIN="$PLATFORM_DOMAIN" \
      gitlab sh -eu -c '
        work=/tmp/gitops-reffix
        rm -rf "$work"
        "$GIT_BIN" -c safe.directory="*" clone -q --depth 1 \
          "http://oauth2:${GL_TOKEN}@localhost/platform/gitops-repository.git" "$work"
        cd "$work/applications/orders-api"
        if grep -rl "registry.devsecops.internal" . >/dev/null 2>&1; then
          grep -rl "registry.devsecops.internal" . | while read -r f; do
            sed -i "s#registry\.devsecops\.internal#registry.${DOMAIN}#g" "$f"
          done
          "$GIT_BIN" -c safe.directory="*" add -A
          "$GIT_BIN" -c safe.directory="*" \
            -c user.name="DevSecOps Platform Bootstrap" -c user.email="devsecops@localhost" \
            commit -q -m "fix(orders-api): image refs -> registry.${DOMAIN} (pinDigest matches images[].name; Kyverno pins registry.${DOMAIN}/*@sha256)"
          "$GIT_BIN" -c safe.directory="*" push -q origin HEAD:main
          echo "GITOPS_REFS_FIXED"
        else
          echo "GITOPS_REFS_ALREADY_OK"
        fi
        rm -rf "$work"
      ' ); then
  log_ok "gitops-repository applications/orders-api refs -> registry.${PLATFORM_DOMAIN}"
else
  die "could not fix the gitops-repository image refs (see output above)"
fi

# --- 5. next steps ------------------------------------------------------------------
log_info "trigger discovery: Jenkins UI → teams → orders → 'Scan Multibranch Pipeline Now'"
log_info "  (the hourly org-folder scan is the safety net; first discovery auto-builds main)"
log_info "instant webhooks afterwards: ./gitlab/scripts/add-webhook.sh $PROJECT_PATH <jenkins-job-full-name>"
