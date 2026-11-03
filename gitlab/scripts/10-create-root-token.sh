#!/usr/bin/env bash
# =============================================================================
# 10-create-root-token.sh — bootstrap an admin PAT for API automation.
#
# The root PASSWORD (secrets/gitlab.env) is not an API token, so we create a
# dedicated 'platform-bootstrap' PAT via gitlab-rails (works before any API
# token exists). Idempotent: reuses the stored token; if the stored token was
# lost but the named token exists, creates a suffixed replacement.
#
# Output: GITLAB_ROOT_TOKEN=… appended to secrets/gitlab.env (mode 0600).
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gitlab-api.sh"
load_env; load_gitlab_secrets
require_cmd jq

wait_for_gitlab

# Does the stored token still work?
if [[ -n "${GITLAB_ROOT_TOKEN:-}" ]]; then
  if [[ "$(gl_api GET /version | jq -r '.version // empty')" != "" ]]; then
    log_ok "stored GITLAB_ROOT_TOKEN is valid (GitLab $(gl_api GET /version | jq -r .version))"
    exit 0
  fi
  log_warn "stored GITLAB_ROOT_TOKEN is invalid/revoked — regenerating"
fi

TOKEN_NAME="platform-bootstrap"
RAILS_OUT="$(gl_compose_exec "${GITLAB_RAILS_RUNNER[@]}" "
u = User.find_by_username('root')
name = '${TOKEN_NAME}'
i = 0
while u.personal_access_tokens.active.find_by(name: name)
  i += 1
  name = '${TOKEN_NAME}-' + i.to_s
end
t = u.personal_access_tokens.new(name: name, scopes: ['api'], expires_at: 364.days.from_now)  # GitLab enforces max PAT lifetime 365d (strict <; 364 = safe margin)
t.set_token(SecureRandom.hex(32))
t.save!
puts t.token
")"

NEW_TOKEN="$(grep -E '^[0-9a-f]{64}$' <<< "$RAILS_OUT" | tail -1)"
if [[ -z "$NEW_TOKEN" ]]; then
  die "rails runner did not return a token. Output was:\n$RAILS_OUT"
fi

append_secret "$ROOT_DIR/secrets/gitlab.env" "GITLAB_ROOT_TOKEN=${NEW_TOKEN}"
export GITLAB_ROOT_TOKEN="$NEW_TOKEN"

# Verify through the API
VERSION="$(gl_api GET /version | jq -r '.version // "UNREACHABLE"')"
[[ "$VERSION" != "UNREACHABLE" ]] || die "freshly created token failed API verification"
log_ok "root PAT created (name='${TOKEN_NAME}'…, expires in 400 days) — GitLab ${VERSION}"
log_info "Rotate per policy (Phase 11 moves platform automation to Vault-issued short-lived tokens)."
