#!/usr/bin/env bash
# =============================================================================
# 50-jenkins-approle.sh — Jenkins ⇄ Vault AppRole (Phase 11, D-36).
#
#   1. policy  jenkins-platform        (vault/policies/jenkins-platform.hcl)
#   2. auth    approle enabled
#   3. role    jenkins-platform        token_ttl=1h token_max_ttl=4h
#   4. creds   → secrets/vault-jenkins.env (VAULT_APPROLE_ID /
#              VAULT_APPROLE_SECRET_ID) → jenkins env_file → JCasC credential
#              'vault-approle' → global vaultConfiguration (50-unclassified)
#              → builds use withVault(...) for dynamic, 1h-lived tokens.
#   5. verifies end-to-end: approle login → read secret/platform/notifications.
#
# ROTATION: rerun this script (mints a fresh secret-id, overwrites the env
# file) then `docker compose up -d jenkins`. secret_id_ttl=0 is deliberate —
# the controller needs the id at boot without an unwrap oracle; tokens stay
# short-lived (1h) and policy-scoped, which is the actual blast-radius bound.
#
# Requires: docker compose (vault UNSEALED), jq, VAULT_ROOT_TOKEN (export or
# secrets/vault-root.env).
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
load_env
require_cmd jq

if [[ -z "${VAULT_ROOT_TOKEN:-}" && -f "$ROOT_DIR/secrets/vault-root.env" ]]; then
  set -a; source "$ROOT_DIR/secrets/vault-root.env"; set +a
fi
[[ -n "${VAULT_ROOT_TOKEN:-}" ]] || die "VAULT_ROOT_TOKEN not set — export it or write secrets/vault-root.env"

vx() {
  ( cd "$ROOT_DIR" && docker compose -f docker-compose.yml exec -T -e VAULT_TOKEN="$VAULT_ROOT_TOKEN" vault vault "$@" )
}
vx status -format=json 2>/dev/null | jq -e '.sealed == false' >/dev/null \
  || die "vault is sealed/unreachable — unseal first (documentation/backup-recovery.md §Vault)"

# --- 1. policy -------------------------------------------------------------------
vx policy write jenkins-platform - < "$ROOT_DIR/vault/policies/jenkins-platform.hcl" >/dev/null
log_ok "policy jenkins-platform written"

# --- 2. approle auth mount ----------------------------------------------------------
vx auth list -format=json | jq -e 'has("approle/")' >/dev/null 2>&1 \
  || { vx auth enable approle >/dev/null; log_ok "approle auth enabled"; }

# --- 3. role ------------------------------------------------------------------------
vx write auth/approle/role/jenkins-platform \
  token_policies=jenkins-platform \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=0 \
  token_period=0 >/dev/null
log_ok "role jenkins-platform configured (token ttl 1h / max 4h)"

# --- 4. credentials → env file -------------------------------------------------------
# Vault 2.x CLI: ALL flags must precede positional args — "-field=… after the
# path" is shipped to the endpoint as a bogus parameter (CLI warns "Command
# flags must be provided before positional arguments") and the capture becomes
# the full response table instead of the field value. Flags-first everywhere.
ROLE_ID="$(vx read -field=role_id auth/approle/role/jenkins-platform/role-id)" \
  || die "failed to obtain role-id"
SECRET_ID="$(vx write -f -field=secret_id auth/approle/role/jenkins-platform/secret-id)" \
  || die "failed to obtain secret-id"
[[ -n "$ROLE_ID" && -n "$SECRET_ID" ]] || die "failed to obtain role-id/secret-id"
ENVF="$ROOT_DIR/secrets/vault-jenkins.env"
mkdir -p "$(dirname "$ENVF")"
umask 077
printf 'VAULT_APPROLE_ID=%s\nVAULT_APPROLE_SECRET_ID=%s\n' "$ROLE_ID" "$SECRET_ID" > "$ENVF"
chmod 600 "$ENVF"; umask 022
log_ok "secrets/vault-jenkins.env written (recreate jenkins to apply: docker compose --profile core up -d --force-recreate jenkins)"

# --- 5. end-to-end verification ------------------------------------------------------
# approle login is an UNAUTHENTICATED path — run it with an explicitly empty
# VAULT_TOKEN (vx() always injects the root token, so bypass the wrapper here)
vx_raw() {
  ( cd "$ROOT_DIR" && docker compose -f docker-compose.yml exec -T -e VAULT_TOKEN="${1:-}" vault \
      vault "${@:2}" )
}
CLIENT_TOKEN="$(vx_raw "" write -f -field=token auth/approle/login role_id="$ROLE_ID" secret_id="$SECRET_ID")" \
  || die "approle login failed — check the policy/role wiring"
[[ -n "$CLIENT_TOKEN" ]] || die "approle login failed — check the policy/role wiring"
vx_raw "$CLIENT_TOKEN" kv get -field=smtp_host secret/platform/notifications >/dev/null 2>&1 \
  || die "client token cannot read secret/platform/notifications — run 40-platform-secrets.sh first"
log_ok "verified: approle login → 1h client token → notifications read"
log_info "builds can now use: withVault([configuration: [vaultUrl: 'http://vault:8200', vaultCredentialId: 'vault-approle', engineVersion: 2], vaultSecrets: [[path: 'secret/platform/notifications', secretValues: [[vaultKey: 'slack_webhook_url']]]]]) { … }"
