#!/usr/bin/env bash
# =============================================================================
# 20-cleanup-policies.sh — retention policies (created BEFORE repositories so
# repos can bind them at creation time; existing repos are re-bound via 30-).
#
# Policy            Format   Criterion                          Bound to
# ----------------- -------- ---------------------------------- -------------------
# cleanup-maven2    maven2   not downloaded 90 d                maven proxies+group
# cleanup-npm       npm      not downloaded 90 d                npm proxy
# cleanup-pypi      pypi     not downloaded 90 d                pypi proxy
# cleanup-nuget     nuget    not downloaded 90 d                nuget proxy
# cleanup-docker    docker   not downloaded 30 d                docker-PROXY only
# cleanup-raw       raw      not downloaded 90 d                raw proxy (future)
#
# SAFETY: cleanup-docker is bound ONLY to the pull-through proxy (cache), never
# to docker-hosted — hosted digests are referenced by gitops-repository and
# must survive until explicitly removed by a release process (D-21).
#
# NOTE: REST criteria are in MINUTES (UI shows days): 90 d = 129600, 30 d = 43200.
# NOTE: Nexus does not expose scheduled-task creation via REST. ONE-TIME manual
# step (installation.md §10.6): enable task "Admin - Cleanup service" (daily)
# so bound policies actually execute.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/nexus-api.sh"
load_env; load_nexus_secrets
require_cmd jq

: "${NEXUS_ADMIN_PASSWORD:?run 10-admin-bootstrap.sh first}"

MINS_90D=129600
MINS_30D=43200

ensure_policy() { # name, format, lastDownloadedMinutes, notes
  local name="$1" format="$2" minutes="$3"
  local existing_id
  existing_id="$(nx_api GET "/cleanup-policies" | jq -r --arg n "$name" '.[] | select(.name==$n) | .id // empty')"
  local body
  body="$(jq -n --arg n "$name" --arg f "$format" --argjson m "$minutes" '{
    name: $n, format: $f, mode: "deletion",
    notes: "Managed by nexus/scripts/20-cleanup-policies.sh (devsecops-platform Phase 5)",
    criteria: { lastDownloaded: $m }
  }')"
  if [[ -n "$existing_id" ]]; then
    local code
    code="$(nx_api_rc PUT "/cleanup-policies/${existing_id}" "$body" | head -1)"
    [[ "$code" == "204" || "$code" == "200" ]] \
      && log_ok "cleanup policy '${name}' updated (format=${format}, lastDownloaded=${minutes}m)" \
      || log_warn "cleanup policy '${name}' update failed (HTTP ${code})"
  else
    local code
    code="$(nx_api_rc POST "/cleanup-policies" "$body" | head -1)"
    [[ "$code" == "201" || "$code" == "200" ]] \
      && log_ok "cleanup policy '${name}' created (format=${format}, lastDownloaded=${minutes}m)" \
      || die "cleanup policy '${name}' creation failed (HTTP ${code})"
  fi
}

ensure_policy "cleanup-maven2" "maven2" "$MINS_90D"
ensure_policy "cleanup-npm"    "npm"    "$MINS_90D"
ensure_policy "cleanup-pypi"   "pypi"   "$MINS_90D"
ensure_policy "cleanup-nuget"  "nuget"  "$MINS_90D"
ensure_policy "cleanup-docker" "docker" "$MINS_30D"
ensure_policy "cleanup-raw"    "raw"    "$MINS_90D"

log_ok "cleanup policies complete — remember the one-time 'Admin - Cleanup service' task (§10.6)"
