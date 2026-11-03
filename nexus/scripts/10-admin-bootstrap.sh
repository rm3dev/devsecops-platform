#!/usr/bin/env bash
# =============================================================================
# 10-admin-bootstrap.sh — Nexus admin password + anonymous access lockdown.
#
# First boot: Nexus writes a random admin password to /nexus-data/admin.password.
# This script rotates it to a generated value stored in secrets/nexus.env
# (0600, gitignored) and deletes the bootstrap file. Idempotent: a stored,
# validating password short-circuits everything.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/nexus-api.sh"
load_env; load_nexus_secrets
require_cmd jq

wait_for_nexus

# ------------------------------------------------------- 1. admin password ---
if [[ -n "${NEXUS_ADMIN_PASSWORD:-}" ]] && nx_validate_auth "admin:${NEXUS_ADMIN_PASSWORD}"; then
  log_ok "stored NEXUS_ADMIN_PASSWORD is valid"
else
  BOOTSTRAP_PW="$(nx_compose_exec sh -c 'cat /nexus-data/admin.password 2>/dev/null' | tr -d '[:space:]' || true)"
  if [[ -n "$BOOTSTRAP_PW" ]] && nx_validate_auth "admin:${BOOTSTRAP_PW}"; then
    NEW_ADMIN_PASSWORD="$(gen_secret)"
    # change-password expects the raw new password as a text/plain body
    CODE="$(nx_compose_exec curl -sS -m 30 -o /tmp/nx-body -w '%{http_code}' -X PUT \
      -u "admin:${BOOTSTRAP_PW}" -H "Content-Type: text/plain" \
      --data "${NEW_ADMIN_PASSWORD}" "${NEXUS_API}/security/users/admin/change-password")"
    [[ "$CODE" == "204" || "$CODE" == "200" ]] || die "admin password change failed (HTTP ${CODE})"
    append_secret "$ROOT_DIR/secrets/nexus.env" "NEXUS_ADMIN_PASSWORD=${NEW_ADMIN_PASSWORD}"
    nx_compose_exec rm -f /nexus-data/admin.password || log_warn "could not remove /nexus-data/admin.password"
    load_nexus_secrets
    nx_validate_auth "admin:${NEXUS_ADMIN_PASSWORD}" || die "new admin password does not validate"
    log_ok "admin password rotated → secrets/nexus.env; bootstrap file removed"
  else
    die "neither a stored password nor /nexus-data/admin.password works.
If the bootstrap file was already deleted and the password is lost, reset via:
  docker compose exec nexus bash -c 'echo admin123 > /nexus-data/admin.password'
is NOT possible after first boot — instead recreate the data dir (drains repos)
or restore from backup (Phase 11)."
  fi
fi

# --------------------------------------------------- 2. anonymous lockdown ----
RESP="$(nx_api_rc PUT "/security/anonymous" '{"enabled":false,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}')"
CODE="$(echo "$RESP" | head -1)"
if [[ "$CODE" == "200" || "$CODE" == "204" ]]; then
  log_ok "anonymous access disabled — all repository access requires authentication"
else
  log_warn "could not update anonymous settings (HTTP ${CODE}) — verify in UI: Security → Anonymous"
fi

# Realms: keep NuGet API-Key + Docker Bearer Token realms active (required for
# docker-group registry auth and nuget pushes); default realm list is fine on OSS.
log_ok "Nexus admin bootstrap complete"
