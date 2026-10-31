#!/usr/bin/env bash
# =============================================================================
# remove-webhook.sh — delete platform webhooks from a project.
#   ./gitlab/scripts/remove-webhook.sh <project-full-path>
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gitlab-api.sh"
load_env; load_gitlab_secrets
require_cmd jq

PROJECT_PATH="${1:?usage: remove-webhook.sh <project-full-path>}"
PID="$(gl_api GET "/projects/$(uri_encode "$PROJECT_PATH")" | jq -r '.id // empty')"
[[ -n "$PID" ]] || die "project '${PROJECT_PATH}' not found"

removed=0
for hook_id in $(gl_api GET "/projects/${PID}/hooks" | jq -r '.[] | select(.url | startswith("http://jenkins:8080/project/")) | .id'); do
  gl_api DELETE "/projects/${PID}/hooks/${hook_id}" >/dev/null && removed=$((removed+1))
done
log_ok "removed ${removed} platform webhook(s) from ${PROJECT_PATH}"
