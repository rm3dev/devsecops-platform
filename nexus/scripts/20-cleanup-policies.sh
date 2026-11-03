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
# NEXUS 3.96+ REALITY (probed live on 3.96.4): the cleanup-policy REST API is
# GONE — GET /v1/cleanup-policies and /beta/... return 404 and swagger.json
# (HTTP 200, ~692 KB) contains zero paths matching cleanup|polic. This script
# therefore PROBES the endpoint first:
#   • API present (older/other Nexus) → create/update all six policies via REST.
#   • API absent  → print the exact one-time UI walkthrough and exit 0 so
#     run-all.sh continues; 30-repositories.sh degrades in step (it skips
#     cleanupPolicyNames bindings, which would otherwise 400 repo creation).
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

# ------------------------------------------------------------------ probe ----
PROBE_CODE="$(nx_api_rc GET "/cleanup-policies" | sed -n '1p')"
if [[ "$PROBE_CODE" != "200" ]]; then
  log_warn "cleanup-policy REST API unavailable (HTTP ${PROBE_CODE}) — removed in Nexus 3.96+."
  log_warn "ONE-TIME UI walkthrough instead (Nexus → sign in as admin):"
  log_warn "  1. ⚙ Admin → Repository → Cleanup Policies → 'Create cleanup policy'"
  while read -r pname pformat pdays; do
    [[ -n "$pname" ]] && log_warn "       • ${pname}: format=${pformat}, 'Remove components NOT downloaded in last ${pdays} days'"
  done <<'TABLE'
cleanup-maven2 maven2 90
cleanup-npm npm 90
cleanup-pypi pypi 90
cleanup-nuget nuget 90
cleanup-docker docker 30
cleanup-raw raw 90
TABLE
  log_warn "  2. Bind policies: Repository → Repositories → <repo> → Cleanup → add policy"
  log_warn "     (maven-central/npm-proxy/pypi-proxy/nuget-proxy/ghcr-proxy/docker-proxy per table;"
  log_warn "      cleanup-docker goes ONLY on docker-PROXY, NEVER on docker-hosted — D-21)."
  log_warn "  3. Admin → System → Tasks → 'Create task' → 'Admin - Cleanup service', daily (§10.6)."
  log_ok "step 20 degraded gracefully (no REST cleanup API in this Nexus version)"
  exit 0
fi

# ------------------------------------------------------- REST path (< 3.96) ----
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
    code="$(nx_api_rc PUT "/cleanup-policies/${existing_id}" "$body" | sed -n '1p')"
    [[ "$code" == "204" || "$code" == "200" ]] \
      && log_ok "cleanup policy '${name}' updated (format=${format}, lastDownloaded=${minutes}m)" \
      || log_warn "cleanup policy '${name}' update failed (HTTP ${code})"
  else
    local code
    code="$(nx_api_rc POST "/cleanup-policies" "$body" | sed -n '1p')"
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
