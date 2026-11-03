#!/usr/bin/env bash
# =============================================================================
# 40-seed-repositories.sh — initial content for the platform repositories.
#
# Seeding runs INSIDE the gitlab container using the omnibus-embedded git
# (http://localhost remote — no host TLS/DNS dependency). Idempotent: skips
# any repository whose 'main' branch already exists.
#
#   platform/devsecops-shared-library ← jenkins/shared-library/ (+ CODEOWNERS)
#   platform/gitops-repository        ← §12 skeleton (clusters/, applications/,
#                                        helm-charts/, README, CODEOWNERS);
#                                        real content lands in Phase 8
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gitlab-api.sh"
load_env; load_gitlab_secrets
require_cmd jq

GIT_BIN=/opt/gitlab/embedded/bin/git

repo_has_main() { # project full path
  local pid; pid="$(gl_api GET "/projects/$(uri_encode "$1")" | jq -r '.id // empty')"
  [[ -n "$pid" ]] || return 1
  gl_api GET "/projects/${pid}/repository/branches/main" | jq -e '.name == "main"' >/dev/null 2>&1
}

push_repo() { # staging_dir, project_full_path
  local staging="$1" full_path="$2"
  local remote_name; remote_name="$(basename "$full_path")"
  local seed_dir="/tmp/seed-${remote_name}"
  if repo_has_main "$full_path"; then
    log_ok "${full_path}: 'main' already seeded — skipping (delete the project to reseed)"
    return 0
  fi
  log_info "seeding ${full_path} from ${staging}…"
  gl_compose_exec rm -rf "$seed_dir"
  gl_compose_exec mkdir -p "$seed_dir"
  ( cd "$ROOT_DIR" && docker compose -f docker-compose.yml cp "${staging}/." "gitlab:${seed_dir}/" >/dev/null ) \
    || die "docker compose cp into gitlab container failed for ${full_path}"

  if ! ( cd "$ROOT_DIR" && docker compose -f docker-compose.yml exec -T \
      -e GL_TOKEN="${GITLAB_ROOT_TOKEN}" -e GL_PATH="${full_path}" -e GL_SEED_DIR="${seed_dir}" \
      -e GIT_BIN="${GIT_BIN}" \
      gitlab sh -eu -c '
        cd "$GL_SEED_DIR"
        "$GIT_BIN" -c safe.directory="*" init -b main . >/dev/null
        "$GIT_BIN" -c safe.directory="*" config user.name "DevSecOps Platform Bootstrap"
        "$GIT_BIN" -c safe.directory="*" config user.email "devsecops@localhost"
        "$GIT_BIN" -c safe.directory="*" add -A
        "$GIT_BIN" -c safe.directory="*" commit -m "chore: initial seed by devsecops-platform Phase 4 bootstrap" >/dev/null
        "$GIT_BIN" -c safe.directory="*" remote add origin "http://oauth2:${GL_TOKEN}@localhost/${GL_PATH}.git"
        "$GIT_BIN" -c safe.directory="*" push -u origin main
      ' ); then
    gl_compose_exec rm -rf "$seed_dir" || true
    die "failed to push ${full_path}"
  fi
  gl_compose_exec rm -rf "$seed_dir" || true
  repo_has_main "$full_path" && log_ok "${full_path}: seeded (branch main)" || die "${full_path}: push reported success but main is missing"
}

# --------------------------------------------- staging: shared library ------
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

LIB_DIR="$STAGING/devsecops-shared-library"
mkdir -p "$LIB_DIR"
cp -r "$ROOT_DIR/jenkins/shared-library/." "$LIB_DIR/"
cat > "$LIB_DIR/CODEOWNERS" <<'EOF'
# CODEOWNERS — enforcement activates with a Premium license (D-19);
# the file is maintained from day one so review routing is ready.
# Replace @root with the platform team group, e.g. @devsecops/platform-engineers
* @root
/jenkins/ @root
/config/platform-config.yaml @root
/resources/security-policy-default.yaml @root
EOF

# --------------------------------------------- staging: gitops skeleton -----
GITOPS_DIR="$STAGING/gitops-repository"
mkdir -p "$GITOPS_DIR"/clusters/{dev,qa,uat,prod} "$GITOPS_DIR"/applications "$GITOPS_DIR"/helm-charts
touch "$GITOPS_DIR"/clusters/{dev,qa,uat,prod}/.gitkeep "$GITOPS_DIR"/applications/.gitkeep "$GITOPS_DIR"/helm-charts/.gitkeep
cat > "$GITOPS_DIR/README.md" <<'EOF'
# GitOps Repository

Single source of truth reconciled by ArgoCD (Phase 8 populates this skeleton).

```
clusters/          per-cluster registration + cluster-scoped policy (dev/qa/uat/prod)
applications/      <service>/base + overlays/<env> (Kustomize)
helm-charts/       microservice-standard chart (shared by all services)
```

Rules:
* Images are referenced **by immutable digest**, updated by the Jenkins
  pipeline (`gitops-write` PAT of the `jenkins-ci` service user) — never by hand
  in production paths.
* `main` is protected: Maintainers push (bot + platform admins); force-push denied.
* No plaintext secrets anywhere — External Secrets Operator / Vault references only.
EOF
cat > "$GITOPS_DIR/CODEOWNERS" <<'EOF'
# Replace @root with real handles (e.g. @devsecops/release-managers for prod)
* @root
/clusters/prod/ @root
/applications/*/overlays/prod/ @root
EOF

push_repo "$LIB_DIR"    "platform/devsecops-shared-library"
push_repo "$GITOPS_DIR" "platform/gitops-repository"

log_ok "repository seeding complete"
