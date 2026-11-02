#!/usr/bin/env bash
# =============================================================================
# run-all.sh — full Phase 5 SonarQube provisioning (idempotent).
#   ./sonarqube/scripts/run-all.sh
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
load_env
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "${C_BOLD}== Phase 5: SonarQube provisioning ==${C_RESET}"
"$HERE/10-admin-bootstrap.sh"  || die "step 10 failed"
"$HERE/20-quality-gates.sh"    || die "step 20 failed"

cat <<EOF

${C_GREEN}${C_BOLD}SonarQube provisioning complete.${C_RESET} Summary:
  admin       : password rotated → secrets/sonar.env
  ci user     : 'jenkins' (Execute Analysis only) → token in secrets/sonar-jenkins.env
  settings    : forceAuthentication=true, serverBaseURL=${SONAR_PUBLIC_URL:-<unset>}
  gates       : platform-default (DEFAULT) + platform-strict
  webhook     : http://jenkins:8080/sonarqube-webhook/ (HMAC) — or scanner-wait fallback

Next:
  docker compose -f docker-compose.yml --profile core up -d jenkins
  (recreate picks up SONARQUBE_TOKEN / SONAR_WEBHOOK_TOKEN → JCasC credentials
   'sonarqube-admin-token' + 'sonarqube-webhook-token' go live)
EOF
