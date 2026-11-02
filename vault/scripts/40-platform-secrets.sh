#!/usr/bin/env bash
# =============================================================================
# 40-platform-secrets.sh — migrate platform operational secrets INTO Vault
# (Phase 11, D-36). One-time seeding + on-demand refresh (FORCE=1 overwrites).
#
#   secret/platform/notifications ← .env (SMTP_*, *_WEBHOOK_URL, mailboxes)
#                                   + secrets/alertmanager/smtp_password
#   secret/platform/cosign        ← secrets/cosign.env (Phase 7 keypair)
#
# Sources are the same values monitoring/scripts/20-configure-notifications.sh
# and security/scripts/10-cosign-keys.sh produced — Vault becomes the source of
# truth; the file copies remain as the bootstrappable fallback (D-34/D-36).
#
# Requires: docker compose (vault running + UNSEALED), jq, VAULT_ROOT_TOKEN
# (export or secrets/vault-root.env — same contract as 30-k8s-auth.sh).
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
load_env
require_cmd jq

if [[ -z "${VAULT_ROOT_TOKEN:-}" && -f "$ROOT_DIR/secrets/vault-root.env" ]]; then
  set -a; source "$ROOT_DIR/secrets/vault-root.env"; set +a
fi
[[ -n "${VAULT_ROOT_TOKEN:-}" ]] || die "VAULT_ROOT_TOKEN not set — export it or write secrets/vault-root.env (from 'vault operator init')"

vx() { # vault CLI inside the container with the root token
  ( cd "$ROOT_DIR" && docker compose -f docker-compose.yml exec -T -e VAULT_TOKEN="$VAULT_ROOT_TOKEN" vault vault "$@" )
}
vx status -format=json 2>/dev/null | jq -e '.sealed == false' >/dev/null \
  || die "vault is sealed/unreachable — unseal it first (see documentation/backup-recovery.md §Vault)"
log_ok "vault unsealed, root token accepted"

# KV v2 at secret/ (30-k8s-auth.sh normally created it; safe to re-assert)
vx secrets list -format=json | jq -e 'has("secret/")' >/dev/null 2>&1 \
  || { vx secrets enable -path=secret kv-v2 >/dev/null; log_ok "KV v2 enabled at secret/"; }

kv_exists() { vx kv metadata get "$1" >/dev/null 2>&1; }
kv_put() { # path key=value…
  local path="$1"; shift
  if [[ "${FORCE:-0}" != "1" ]] && kv_exists "$path"; then
    log_ok "exists (skipped, FORCE=1 to overwrite): $path"; return
  fi
  vx kv put "$path" "$@" >/dev/null
  log_ok "written: $path"
}

# --- notifications -------------------------------------------------------------
SMTP_PW="$(cat "$ROOT_DIR/secrets/alertmanager/smtp_password" 2>/dev/null || true)"
[[ "$SMTP_PW" == "SET_IN_PHASE_10" ]] && SMTP_PW=""
kv_put secret/platform/notifications \
  smtp_host="${SMTP_HOST:-}" \
  smtp_port="${SMTP_PORT:-587}" \
  smtp_user="${SMTP_USER:-}" \
  smtp_password="${SMTP_PW}" \
  smtp_from="${SMTP_FROM:-devsecops-platform@${PLATFORM_DOMAIN:-localhost}}" \
  email_to="${NOTIFICATION_EMAIL_TO:-}" \
  oncall_to="${ONCALL_EMAIL_TO:-}" \
  slack_webhook_url="${SLACK_WEBHOOK_URL:-}" \
  teams_webhook_url="${TEAMS_WEBHOOK_URL:-}"

# --- cosign signing keypair (D-25) ----------------------------------------------
if [[ -f "$ROOT_DIR/secrets/cosign.env" ]]; then
  set -a; source "$ROOT_DIR/secrets/cosign.env"; set +a
  if [[ -n "${COSIGN_KEY:-}" && "$COSIGN_KEY" != "SET_IN_PHASE_7" ]]; then
    kv_put secret/platform/cosign \
      private-key="$COSIGN_KEY" \
      password="${COSIGN_PASSWORD:-}"
  else
    log_warn "secrets/cosign.env still placeholder — run security/scripts/10-cosign-keys.sh, then rerun (FORCE=1)"
  fi
else
  log_warn "secrets/cosign.env absent — cosign migration skipped"
fi

log_ok "platform secrets seeded. Next: vault/scripts/50-jenkins-approle.sh (Jenkins read access)"
