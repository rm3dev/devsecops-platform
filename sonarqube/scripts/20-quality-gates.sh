#!/usr/bin/env bash
# =============================================================================
# 20-quality-gates.sh — organization quality gates (Phase 5, decision D-20).
#
#   platform-default  (set as the DEFAULT gate for every new project)
#       new code coverage              ≥ 80 %
#       new duplicated lines           ≤ 3 %
#       maintainability / reliability /
#       security / security-review     = A on new code
#   platform-strict   (prod-critical services; opt-in via sonar.qualitygate
#                      property in devsecops.yaml or per-project setting)
#       coverage ≥ 90 %, duplicates ≤ 1 %, ratings A, zero new accepted issues
#
# Conditions are declared idempotently: existing conditions on the managed
# gates are deleted and recreated so this script is the single source of truth.
# Rating metric values: 1.0=A 2.0=B 3.0=C 4.0=D 5.0=E (op GT 1.0 → fail B+).
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sonar-api.sh"
load_env; load_sonar_secrets
require_cmd jq

: "${SONAR_ADMIN_PASSWORD:?run 10-admin-bootstrap.sh first}"

# gate-name|metric|op|error-threshold   (op: LT=fail below, GT=fail above)
GATE_DEFAULT="platform-default"
GATE_STRICT="platform-strict"

DEFAULT_CONDITIONS="
new_coverage|LT|80
new_duplicated_lines_density|GT|3
new_maintainability_rating|GT|1.0
new_reliability_rating|GT|1.0
new_security_rating|GT|1.0
new_security_review_rating|GT|1.0
"
STRICT_CONDITIONS="
new_coverage|LT|90
new_duplicated_lines_density|GT|1
new_maintainability_rating|GT|1.0
new_reliability_rating|GT|1.0
new_security_rating|GT|1.0
new_security_review_rating|GT|1.0
new_accepted_issues|GT|0
"

ensure_gate() { # gate_name, conditions_multiline
  local gate="$1" conditions="$2"
  local exists
  exists="$(sq_api GET "/qualitygates/list" | jq -r --arg g "$gate" '[.qualitygates[] | select(.name==$g)] | length')"
  if [[ "$exists" == "0" ]]; then
    sq_api POST "/qualitygates/create" "name=${gate}" >/dev/null || die "quality gate create failed: ${gate}"
    log_ok "quality gate '${gate}' created"
  else
    log_info "quality gate '${gate}' exists"
  fi

  # Wipe managed conditions, re-apply from declaration above (idempotent sync)
  local cid
  for cid in $(sq_api GET "/qualitygates/show?name=${gate}" | jq -r '.conditions[]?.id // empty'); do
    sq_api POST "/qualitygates/delete_condition" "id=${cid}" >/dev/null || log_warn "could not delete condition ${cid}"
  done
  local line metric op val
  while IFS='|' read -r metric op val; do
    [[ -z "${metric// }" ]] && continue
    sq_api POST "/qualitygates/create_condition" \
      "gateName=${gate}&metric=${metric}&op=${op}&error=${val}" >/dev/null \
      || die "condition failed: ${gate} ${metric} ${op} ${val}"
    log_info "  condition: ${metric} ${op} ${val} → ${gate}"
  done <<< "$conditions"
  log_ok "quality gate '${gate}' conditions synced ($(grep -c '|' <<< "$conditions") conditions)"
}

ensure_gate "$GATE_DEFAULT" "$DEFAULT_CONDITIONS"
ensure_gate "$GATE_STRICT"  "$STRICT_CONDITIONS"

# Default gate for all NEW projects
sq_api POST "/qualitygates/set_as_default" "name=${GATE_DEFAULT}" >/dev/null \
  && log_ok "'${GATE_DEFAULT}' is the default gate for new projects" \
  || log_warn "set_as_default failed (may already be default)"

# Note: Community Build has no branch/MR analysis — runSonarAnalysis isolates
# non-main branches into separate project keys (documented CE limitation).
log_ok "quality gates complete"
