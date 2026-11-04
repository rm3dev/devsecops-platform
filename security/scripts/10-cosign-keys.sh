#!/usr/bin/env bash
# =============================================================================
# 10-cosign-keys.sh — generate the platform image-signing keypair (Phase 7).
#
# Uses the already-built agent-security image (cosign binary inside) so the
# HOST needs no cosign installation. Outputs:
#   secrets/cosign/cosign.key        private key PEM (0600)  — NEVER in Git
#   secrets/cosign/cosign.pub        public key (Phase 8: Kyverno verify policy)
#   secrets/cosign.env               COSIGN_KEY (base64 PEM) + COSIGN_PASSWORD
#                                    → consumed by JCasC credentials
#                                      'cosign-signing-key'/'…-password'
# Phase 11 migrates this material into Vault (transit keys + rotation); until
# then the keypair is platform-static — protect secrets/ like any root material.
#
# Idempotent: existing keypair is validated and reused, never overwritten.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
load_env
require_cmd docker

KEYS_DIR="$ROOT_DIR/secrets/cosign"
COSIGN_ENV="$ROOT_DIR/secrets/cosign.env"
IMAGE="devsecops/agent-security:${AGENT_IMAGE_TAG:-1.0.0}"

docker image inspect "$IMAGE" >/dev/null 2>&1 \
  || die "image ${IMAGE} missing — run: ./scripts/build-images.sh --agent security"

mkdir -p "$KEYS_DIR"; chmod 700 "$KEYS_DIR"
# NOTE: agent-security ends with USER jenkins (uid 1000) — the keypair runs
# need --user root to enter the root-owned 0700 keys dir (dash reports the
# permission failure misleadingly as "can't cd to /keys").

if [[ -s "$KEYS_DIR/cosign.key" && -s "$KEYS_DIR/cosign.pub" ]]; then
  log_ok "existing cosign keypair found in secrets/cosign/ — reusing (delete the directory to regenerate)"
  # ensure cosign.env reflects the on-disk key (e.g. after a partial earlier run)
  source "$COSIGN_ENV" 2>/dev/null || true
  if [[ "${COSIGN_KEY:-SET_IN_PHASE_7}" == "SET_IN_PHASE_7" ]]; then
    PW="$(grep -oP '(?<=^COSIGN_PASSWORD=).*' "$COSIGN_ENV" 2>/dev/null || true)"
    [[ -n "$PW" && "$PW" != "SET_IN_PHASE_7" ]] || PW="$(gen_secret)"
    append_secret "$COSIGN_ENV" "COSIGN_PASSWORD=${PW}"
    append_secret "$COSIGN_ENV" "COSIGN_KEY=$(base64 -w0 "$KEYS_DIR/cosign.key")"
    log_ok "secrets/cosign.env synced with on-disk keypair"
  fi
else
  COSIGN_PASSWORD_VALUE="$(gen_secret)"
  log_info "generating cosign keypair inside ${IMAGE}…"
  docker run --rm \
    --user root \
    -v "$KEYS_DIR":/keys \
    -e COSIGN_PASSWORD="$COSIGN_PASSWORD_VALUE" \
    --entrypoint sh "$IMAGE" -c \
    'cd /keys && cosign generate-key-pair --output-key-prefix cosign' \
    || die "cosign generate-key-pair failed"
  chmod 600 "$KEYS_DIR/cosign.key"; chmod 644 "$KEYS_DIR/cosign.pub"
  append_secret "$COSIGN_ENV" "COSIGN_PASSWORD=${COSIGN_PASSWORD_VALUE}"
  append_secret "$COSIGN_ENV" "COSIGN_KEY=$(base64 -w0 "$KEYS_DIR/cosign.key")"
  log_ok "keypair generated → secrets/cosign/{cosign.key,cosign.pub}; env → secrets/cosign.env"
fi

# Sanity: verify with cosign itself, NOT openssl. Cosign encrypts cosign.key
# with its own scrypt-based PKCS#8 scheme — OpenSSL 3 recognizes the envelope
# but cannot decrypt it ("unsupported … Input structure: EncryptedPrivateKeyInfo",
# even with the correct -passin; live-proven twice). `cosign public-key`
# decrypts with COSIGN_PASSWORD and derives the pubkey; diffing against
# cosign.pub validates key + stored password + consistency in one shot.
docker run --rm --user root -v "$KEYS_DIR":/keys -e COSIGN_PASSWORD="$(grep -oP '(?<=^COSIGN_PASSWORD=).*' "$COSIGN_ENV")" \
  --entrypoint sh "$IMAGE" -c \
  'cosign public-key --key /keys/cosign.key | diff - /keys/cosign.pub' \
  && log_ok "keypair verified with cosign: COSIGN_PASSWORD decrypts cosign.key, derived public key matches cosign.pub" \
  || log_warn "private key parse check failed — verify manually before relying on signing"

cat <<EOF

Next steps:
  1) docker compose -f docker-compose.yml --profile core up -d jenkins
     (recreate loads COSIGN_KEY/COSIGN_PASSWORD → JCasC credentials go live)
  2) Back up secrets/cosign/ with the platform backups (restic scope covers secrets/).
  3) Phase 8 publishes cosign.pub into the Kyverno ClusterPolicy that admits
     ONLY signed images (verifyImages) — keep the file available.
EOF
