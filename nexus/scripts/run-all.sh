#!/usr/bin/env bash
# =============================================================================
# run-all.sh — full Phase 5 Nexus provisioning (idempotent).
#   ./nexus/scripts/run-all.sh
# Order matters: admin → cleanup policies → repositories (bind policies) → users.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/nexus-api.sh"
load_env
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "${C_BOLD}== Phase 5: Nexus Repository provisioning ==${C_RESET}"
"$HERE/10-admin-bootstrap.sh"     || die "step 10 failed"
"$HERE/20-cleanup-policies.sh"    || die "step 20 failed"
"$HERE/30-repositories.sh"        || die "step 30 failed"
"$HERE/40-users-roles.sh"         || die "step 40 failed"

# Registry endpoint probe through Traefik (docker-group connector :8085).
# 401 = registry alive, auth required (expected with forceBasicAuth + no creds).
REG_CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
  --resolve "registry.${PLATFORM_DOMAIN}:443:127.0.0.1" \
  "https://registry.${PLATFORM_DOMAIN}/v2/" || echo 000)"
case "$REG_CODE" in
  401|200) log_ok "docker registry reachable via Traefik: https://registry.${PLATFORM_DOMAIN}/v2/ (HTTP ${REG_CODE})" ;;
  *)       log_warn "registry probe returned HTTP ${REG_CODE} — Traefik up? docker-group created? (re-check: ./scripts/health-check.sh)" ;;
esac

cat <<EOF

${C_GREEN}${C_BOLD}Nexus provisioning complete.${C_RESET} Summary:
  admin    : password rotated → secrets/nexus.env; anonymous access disabled
  proxies  : maven-central, npm, pypi, nuget, docker (with cleanup policies)
  hosted   : maven-releases/snapshots, npm, pypi, nuget, raw, docker
  groups   : maven-public, npm-public, pypi-public, nuget-public,
             docker-group (connector :${NEXUS_DOCKER_GROUP_PORT:-8085} → registry.${PLATFORM_DOMAIN})
  ci user  : jenkins-ci (role jenkins-deploy: read-all, publish-hosted, no delete)
             → secrets/nexus-jenkins.env

ONE-TIME manual step (no REST API for scheduled tasks, installation.md §10.6):
  Nexus UI → System → Tasks → Create:
    1. "Admin - Cleanup service"        (daily, e.g. 02:00) — runs bound policies
    2. "Remove snapshots from Maven repository" on maven-snapshots (daily, keep 3 versions)

Next:
  docker compose -f docker-compose.yml --profile core up -d jenkins
  (recreate picks up NEXUS_DEPLOY_* → JCasC credential 'nexus-deploy' goes live)
EOF
