#!/usr/bin/env bash
# =============================================================================
# 15-application-settings.sh — enforce application settings at the DB level.
#
# WHY THIS SCRIPT EXISTS (found the hard way on a live deployment):
#   The omnibus entrypoint writes GITLAB_OMNIBUS_CONFIG into /etc/gitlab/gitlab.rb
#   only on FIRST initialization. Whenever the gitlab volume already exists
#   (recreate after a config change, redeploy over an existing DATA_ROOT),
#   compose's gitlab_rails['allow_local_requests_from_web_hooks_and_services']=true
#   NEVER reaches the database — and webhooks to internal services
#   (http://jenkins:8080/...) are rejected with {"error":"Invalid url given"}.
#
#   So we set such flags idempotently via gitlab-psql: instant (no reconfigure),
#   durable (DB volume), and never stomped by future reconfigures (the key is
#   absent from gitlab.rb). Rails re-reads application settings from its
#   in-memory cache within ~60 seconds.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gitlab-api.sh"
load_env; load_gitlab_secrets
wait_for_gitlab

psql_exec() { gl_compose_exec gitlab-psql -d gitlabhq_production -qtAc "$1"; }

log_info "applying application settings directly in the database (gitlab-psql)..."

VAL="$(psql_exec "UPDATE application_settings SET allow_local_requests_from_web_hooks_and_services = true RETURNING allow_local_requests_from_web_hooks_and_services;" || true)"
if [[ "$VAL" == "t" ]]; then
  log_ok "allow_local_requests_from_web_hooks_and_services = true (webhooks to internal hosts like jenkins:8080 permitted)"
else
  die "could not set allow_local_requests_from_web_hooks_and_services (psql returned: '${VAL}')"
fi

log_info "Rails picks up application-setting changes within ~60s (in-memory cache)."
