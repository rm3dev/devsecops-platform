#!/usr/bin/env bash
# =============================================================================
# add-webhook.sh — register the Jenkins GitLab-plugin webhook on a project.
#
#   ./gitlab/scripts/add-webhook.sh <project-full-path> <jenkins-job-full-name>
#   e.g. ./gitlab/scripts/add-webhook.sh teams/payments/payment-service \
#            teams/payments/payment-service
#
# Webhook target: http://jenkins:8080/project/<jenkins-job-full-name> over the
# INTERNAL scm-network (D-18; GitLab is configured with
# allow_local_requests_from_web_hooks_and_services=true). Shared secret from
# secrets/gitlab-jenkins.env (GITLAB_WEBHOOK_TOKEN) — the same value is
# configured in the Jenkins GitLab connection (Phase 6).
#
# NOTE (CE): project webhooks are used because GROUP webhooks are Premium.
# Phase 6's seed job calls this script for every discovered application repo.
# Idempotent: replaces an existing hook with the same URL.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gitlab-api.sh"
load_env; load_gitlab_secrets
require_cmd jq

PROJECT_PATH="${1:?usage: add-webhook.sh <project-full-path> <jenkins-job-full-name>}"
JOB_NAME="${2:?usage: add-webhook.sh <project-full-path> <jenkins-job-full-name>}"
WEBHOOK_URL="http://jenkins:8080/project/${JOB_NAME}"
: "${GITLAB_WEBHOOK_TOKEN:?GITLAB_WEBHOOK_TOKEN missing in secrets/gitlab-jenkins.env}"

PID="$(gl_api GET "/projects/$(uri_encode "$PROJECT_PATH")" | jq -r '.id // empty')"
[[ -n "$PID" ]] || die "project '${PROJECT_PATH}' not found"

# Remove a previous hook with the same URL (idempotency)
for hook_id in $(gl_api GET "/projects/${PID}/hooks" | jq -r --arg u "$WEBHOOK_URL" '.[] | select(.url==$u) | .id'); do
  gl_api DELETE "/projects/${PID}/hooks/${hook_id}" >/dev/null
  log_info "removed stale webhook ${hook_id}"
done

gl_api POST "/projects/${PID}/hooks" "$(jq -n --arg u "$WEBHOOK_URL" --arg t "$GITLAB_WEBHOOK_TOKEN" '{
  url: $u,
  token: $t,
  push_events: true,
  push_events_branch_filter: "",
  merge_requests_events: true,
  tag_push_events: true,
  enable_ssl_verification: false,
  confidential_issues_events: false,
  note_events: false
}')" | jq -e '.id' >/dev/null || die "webhook creation failed for ${PROJECT_PATH}"

log_ok "webhook → ${WEBHOOK_URL} registered on ${PROJECT_PATH} (push/MR/tag events, shared secret set)"
log_info "Until the matching Jenkins job exists (Phase 6 multibranch seed), deliveries will report HTTP 404 — GitLab retries automatically on the next event."
