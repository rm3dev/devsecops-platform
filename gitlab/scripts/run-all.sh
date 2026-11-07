#!/usr/bin/env bash
# =============================================================================
# run-all.sh — full Phase 4 GitLab provisioning (idempotent, re-runnable).
#
#   ./gitlab/scripts/run-all.sh
#
# Sequence: wait for GitLab → root PAT → groups/users/PATs → projects +
# protection + memberships → seed repositories → project-scoped library token +
# group-scoped read-only team checkout token → webhook → connectivity check.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gitlab-api.sh"
load_env
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "${C_BOLD}== Phase 4: GitLab provisioning ==${C_RESET}"
"$HERE/10-create-root-token.sh"   || die "step 10 failed"
# DB-level application settings (survives the omnibus first-init-only quirk —
# see header of 15-application-settings.sh; webhooks depend on it)
"$HERE/15-application-settings.sh" || die "step 15 failed"
"$HERE/20-users-groups.sh"        || die "step 20 failed"
"$HERE/30-projects.sh"            || die "step 30 failed"
"$HERE/40-seed-repositories.sh"   || die "step 40 failed"
# Phase 8: replace the gitops skeleton with real content (chart/clusters/apps)
# + verify the gitops-write / argocd-read PATs. Safe to run from day one
# (idempotent; preserves CI-committed digests on re-runs).
"$HERE/50-gitops-repository.sh"   || die "step 50 failed"
"$HERE/55-library-read-token.sh" || die "step 55 failed"
"$HERE/56-teams-read-token.sh"   || die "step 56 failed"

# Webhook for the shared-library repo (matching Jenkins job is seeded Phase 6;
# deliveries 404 harmlessly until then — documented in add-webhook.sh).
"$HERE/add-webhook.sh" "platform/devsecops-shared-library" "platform/devsecops-shared-library" || log_warn "webhook step failed (continue manually)"

# GitLab → Jenkins internal connectivity (D-18 prerequisite for webhooks)
CODE="$(gl_compose_exec curl -sS -m 10 -o /dev/null -w '%{http_code}' http://jenkins:8080/login || echo 000)"
if [[ "$CODE" == "200" ]]; then
  log_ok "GitLab→Jenkins internal reachability verified (http://jenkins:8080 → HTTP 200)"
else
  log_warn "GitLab cannot reach http://jenkins:8080 (HTTP ${CODE}) — is the core profile running?"
fi

cat <<EOF

${C_GREEN}${C_BOLD}Phase 4 complete.${C_RESET} Summary:
  groups      : platform, teams (private)
  users       : jenkins-ci (PATs: ci-api, gitops-write), argocd
  library     : project deploy token (read_repository only; scoped to shared library)
  team clones : group deploy token (read_repository only; scoped to teams/*)
  projects    : platform/devsecops-shared-library (MR-gated, main protected, v* tags)
                platform/gitops-repository (maintainer-push main, rel-* tags, ff merges)
  memberships : jenkins-ci → library(Reporter), gitops(Maintainer), teams(Developer)
                argocd    → gitops(Reporter)
  webhook     : shared-library → http://jenkins:8080/project/platform/devsecops-shared-library

Next steps:
  1) Refresh Jenkins so JCasC loads the project-only library credential:
       docker compose -f docker-compose.yml --profile core up -d --no-deps --force-recreate jenkins
     (secrets/gitlab-jenkins.env changed; JCasC applies Global-scoped
      'gitlab-library-readonly' and 'gitlab-teams-readonly' credentials)
  2) Verify: https://gitlab.${PLATFORM_DOMAIN}  (root login — secrets/gitlab.env)
  3) Application repositories get webhooks when Phase 6 seeds the multibranch
     jobs (seed job invokes add-webhook.sh per project).
EOF
