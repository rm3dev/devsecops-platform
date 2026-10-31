#!/usr/bin/env bash
# =============================================================================
# 60-audit-enable.sh — Vault audit device (Phase 11).
#
# Enables the file audit device at /vault/file/audit.log (inside the raft data
# volume → covered by restic AND by native-dumps staging). Every request/
# response is logged with HMAC-hashed tokens — safe to ship to Loki, which
# Alloy tails as service="vault-audit" (monitoring/alloy/config.alloy).
#
# NOTE: while an audit device is enabled but its backend is unwritable, Vault
# REFUSES all requests (fail-closed by design). /vault/file is a mounted
# volume — verify free disk space (HostDiskSpaceLow alert covers it).
#
# Idempotent. Requires: docker compose (vault UNSEALED), jq, VAULT_ROOT_TOKEN.
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

if vx audit list -format=json | jq -e 'has("file/") and .["file/"].enabled' >/dev/null 2>&1; then
  log_ok "file audit device already enabled"
else
  vx audit enable file file_path=/vault/file/audit.log >/dev/null
  log_ok "file audit device enabled → /vault/file/audit.log"
fi

# proof: the audit device answers a self-read
vx read sys/audit >/dev/null && log_ok "verified: sys/audit readable, device active"
log_info "Loki stream: {service=\"vault-audit\"} (Alloy tails the file; enable requires the compose volume from Phase 11)"
