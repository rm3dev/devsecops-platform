#!/usr/bin/env bash
# =============================================================================
# cosign-public-key.sh — (re)apply the verify-image-signature ClusterPolicy
# with the CURRENT platform public key injected (yq, indentation-safe).
#
# Key source: secrets/cosign/cosign.pub (security/scripts/10-cosign-keys.sh).
# Re-run this script after ANY key rotation — the policy carries the key
# inline (Kyverno verifyImages does not read Kubernetes secrets).
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
load_env
require_cmd kubectl yq

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUB="$ROOT_DIR/secrets/cosign/cosign.pub"
[[ -s "$PUB" ]] || die "missing $PUB — run security/scripts/10-cosign-keys.sh (Phase 7) first"
grep -q "BEGIN PUBLIC KEY" "$PUB" || die "$PUB does not look like a PEM public key"

if [[ -z "${KUBECONFIG:-}" && -f /etc/rancher/k3s/k3s.yaml ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
PLATFORM_DOMAIN="$PLATFORM_DOMAIN" envsubst '${PLATFORM_DOMAIN}' \
  < "$SCRIPT_DIR/policies/verify-image-signature.yaml" > "$TMP"
COSIGN_PUB="$(cat "$PUB")" yq -i \
  '.spec.rules[0].verifyImages[0].attestors[0].entries[0].keys.publicKeys = strenv(COSIGN_PUB)' \
  "$TMP"
kubectl apply -f "$TMP" >/dev/null
log_ok "ClusterPolicy verify-image-signature applied with public key $(sha256sum "$PUB" | cut -c1-12)… (re-run after key rotation)"
