#!/usr/bin/env bash
# =============================================================================
# 30-projects.sh — platform projects, settings, branch/tag protection,
# memberships and (graceful) merge-approval configuration.
#
# Projects (namespace 'platform', private):
#   devsecops-shared-library — the pipeline framework (seeded by 40-)
#   gitops-repository        — clusters/applications/helm-charts (Phase 8 fills)
#
# CE-tier honesty (architecture D-19): merge-approval RULES, CODEOWNERS
# enforcement, push rules and group webhooks are PREMIUM features. This script
# ATTEMPTS the approvals API and degrades with a clear warning on CE; the CE
# enforcement baseline is: protected branches/tags + 'pipelines must succeed'
# + MR-only flow + CODEOWNERS files seeded for when a license is applied.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gitlab-api.sh"
load_env; load_gitlab_secrets
require_cmd jq

get_group_id() { gl_api GET "/groups/$(uri_encode "$1")" | jq -r '.id // empty'; }
get_user_id()  { gl_api GET "/users?username=$1" | jq -r '.[0]?.id // empty'; }  # .[0]? survives error-object bodies (401/429) instead of killing set -e
get_project_id() { gl_api GET "/projects/$(uri_encode "$1")" | jq -r '.id // empty'; }

PLATFORM_GROUP_ID="$(get_group_id platform)"; [[ -n "$PLATFORM_GROUP_ID" ]] || die "group 'platform' missing — run 20-users-groups.sh"
TEAMS_GROUP_ID="$(get_group_id teams)"

ensure_project() { # full_path, name, settings-json
  local full_path="$1" name="$2" settings="$3"
  local pid; pid="$(get_project_id "$full_path")"
  if [[ -z "$pid" ]]; then
    pid="$(gl_api POST /projects "$(jq -n --arg n "$name" --argjson ns "$PLATFORM_GROUP_ID" \
            '{name:$n, path:$n, namespace_id:$ns, visibility:"private", default_branch:"main", initialize_with_readme:false}')" \
            | jq -r '.id // empty')"
    [[ -n "$pid" ]] || die "failed to create project ${full_path}"
    log_info "project ${full_path} created (id=${pid})"
  else
    log_ok "project ${full_path} exists (id=${pid})"
  fi
  gl_api PUT "/projects/${pid}" "$settings" | jq -e '.id' >/dev/null \
    && log_ok "settings applied to ${full_path}" \
    || log_warn "settings PUT returned an error for ${full_path} (inspect manually)"
  echo "$pid" > "/tmp/.gl-pid-${name}"
}

# --- shared library project: MR flow gated by CI -----------------------------
ensure_project "platform/devsecops-shared-library" "devsecops-shared-library" "$(jq -n '{
  merge_method: "merge",
  only_allow_merge_if_pipeline_succeeds: true,
  allow_merge_on_skipped_pipeline: false,
  remove_source_branch_after_merge: true,
  description: "Jenkins shared library — the standard microservice pipeline framework (devsecops-platform/jenkins/shared-library)"
}')"

# --- gitops repository: bot commits directly to main (ff, no MR gate) --------
ensure_project "platform/gitops-repository" "gitops-repository" "$(jq -n '{
  merge_method: "ff",
  only_allow_merge_if_pipeline_succeeds: false,
  remove_source_branch_after_merge: true,
  description: "GitOps source of truth: clusters/, applications/, helm-charts/ (reconciled by ArgoCD — Phase 8)"
}')"

SL_PID="$(cat /tmp/.gl-pid-devsecops-shared-library)"
GO_PID="$(cat /tmp/.gl-pid-gitops-repository)"
rm -f /tmp/.gl-pid-devsecops-shared-library /tmp/.gl-pid-gitops-repository

# ------------------------------------------------- protected branches/tags ---
protect_branch() { # pid, branch, push_level, merge_level
  local pid="$1" br="$2" push="$3" merge="$4"
  gl_api DELETE "/projects/${pid}/protected_branches/${br}" >/dev/null 2>&1 || true
  gl_api POST "/projects/${pid}/protected_branches" \
    "$(jq -n --arg n "$br" --argjson p "$push" --argjson m "$merge" \
       '{name:$n, push_access_level:$p, merge_access_level:$m, allow_force_push:false}')" \
    | jq -e '.name' >/dev/null && log_ok "protected branch '${br}' (push=${push}, merge=${merge}) on project ${pid}" \
    || log_warn "could not protect branch '${br}' on project ${pid}"
}
protect_tag() { # pid, pattern
  local pid="$1" pattern="$2"
  local existing
  existing="$(gl_api GET "/projects/${pid}/protected_tags/$(uri_encode "$pattern")" | jq -r '.name // empty')"
  if [[ -z "$existing" ]]; then
    gl_api POST "/projects/${pid}/protected_tags" \
      "$(jq -n --arg n "$pattern" '{name:$n, create_access_level:40}')" | jq -e '.name' >/dev/null \
      && log_ok "protected tag '${pattern}' on project ${pid}" \
      || log_warn "could not protect tag '${pattern}' on project ${pid}"
  else
    log_ok "protected tag '${pattern}' exists on project ${pid}"
  fi
}

# Access levels: 0=No one, 30=Developer, 40=Maintainer
protect_branch "$SL_PID" "main" 0 40      # library main: MR-only, maintainers merge
protect_branch "$GO_PID" "main" 40 40     # gitops main: maintainers (jenkins-ci bot + admins) push
protect_tag    "$SL_PID" "v*"
protect_tag    "$GO_PID" "rel-*"

# ------------------------------------------------------------ memberships ----
ensure_member() { # scope(project|group), id, user_id, access_level
  local scope="$1" target="$2" uid="$3" level="$4"
  local resp code
  # GitLab semantics: PUT /members/:uid EDITS an existing member and 404s for
  # non-members; adding requires POST /members (pattern proven live by
  # 50-gitops-repository.sh). Whole response captured (no pipes → no SIGPIPE).
  resp="$(gl_api_rc PUT "/${scope}s/${target}/members/${uid}" "$(jq -n --argjson l "$level" '{access_level:$l}')")"
  code="${resp%%$'\n'*}"
  if [[ "$code" == "404" ]]; then
    resp="$(gl_api_rc POST "/${scope}s/${target}/members" "$(jq -n --argjson u "$uid" --argjson l "$level" '{user_id:$u, access_level:$l}')")"
    code="${resp%%$'\n'*}"
  fi
  case "$code" in
    200|201) log_ok "member uid=${uid} → ${scope} ${target} (access=${level})" ;;
    *)       log_warn "membership uid=${uid} → ${scope} ${target} HTTP ${code}: $(tail -n +2 <<<"$resp" | head -c 200)" ;;
  esac
}
JENKINS_CI_ID="$(get_user_id jenkins-ci || true)"; [[ -n "$JENKINS_CI_ID" ]] || die "jenkins-ci missing — run 20-users-groups.sh"
ARGOCD_ID="$(get_user_id argocd || true)"; [[ -n "$ARGOCD_ID" ]] || die "argocd missing — run 20-users-groups.sh"

ensure_member project "$SL_PID" "$JENKINS_CI_ID" 20    # Reporter: clone library
ensure_member project "$GO_PID" "$JENKINS_CI_ID" 40    # Maintainer: commit digest updates to main
ensure_member group   "$TEAMS_GROUP_ID" "$JENKINS_CI_ID" 30  # Developer: clone app repos + commit statuses
ensure_member project "$GO_PID" "$ARGOCD_ID" 20        # Reporter: ArgoCD read-only pulls (Phase 8)

# ------------------------------------------------------- merge approvals -----
# Premium feature — attempted, gracefully degraded on CE (D-19).
for pid_name in "${SL_PID}:devsecops-shared-library"; do
  pid="${pid_name%%:*}"; name="${pid_name##*:}"
  code="$(gl_api_rc POST "/projects/${pid}/approvals" '{"approvals_before_merge":1}' | sed -n '1p')"
  if [[ "$code" == "200" || "$code" == "201" ]]; then
    log_ok "merge approvals (1) configured for ${name}"
  else
    log_warn "merge approvals API returned HTTP ${code} for ${name} — PREMIUM feature; on CE the MR-only flow + protected branches + 'pipelines must succeed' provide the gate. CODEOWNERS files are seeded and activate automatically with a license."
  fi
done

log_ok "projects configured"
