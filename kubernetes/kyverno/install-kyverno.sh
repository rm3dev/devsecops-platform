#!/usr/bin/env bash
# =============================================================================
# install-kyverno.sh — pinned Kyverno v${KYVERNO_VERSION} + platform policies.
#
#   * Lab clusters are single-node: replicas scaled to ${KYVERNO_REPLICAS:-1}
#     (install.yaml ships HA=3). Set KYVERNO_REPLICAS=3 on real clusters.
#   * TLS_MODE=internal-ca: the admission controller gets the platform CA
#     mounted + SSL_CERT_FILE, so cosign verification can fetch signatures
#     from registry.<domain> over the internal TLS chain.
#   * Policies applied (templates — ${PLATFORM_DOMAIN} via envsubst):
#       verify-image-signature   images from the platform registry must carry a
#                                cosign signature from secrets/cosign/cosign.pub
#                                (Phase 7 keypair — D-25/D-28)
#       require-digest-pinning   workload images must be digest references to
#                                the platform registry (no mutable tags, no
#                                foreign registries — D-26)
#
# Idempotent. Requires: kubectl, yq (v4). Prereq: namespaces applied
# (argocd/install-argocd.sh or scripts/00-bootstrap-cluster.sh does this),
# security/scripts/10-cosign-keys.sh already run (cosign.pub exists).
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
load_env
require_cmd kubectl yq curl

KYVERNO_VERSION="${KYVERNO_VERSION:-v1.19.2}"
KYVERNO_REPLICAS="${KYVERNO_REPLICAS:-1}"
KYVERNO_NS=kyverno
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${KUBECONFIG:-}" && -f /etc/rancher/k3s/k3s.yaml ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi
kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster (KUBECONFIG=${KUBECONFIG:-unset})"

log_info "installing Kyverno ${KYVERNO_VERSION}…"
kubectl apply -f "$ROOT_DIR/kubernetes/namespaces.yaml" >/dev/null
INSTALL_YAML="$(mktemp)"; trap 'rm -f "$INSTALL_YAML"' EXIT
curl -fsSL -o "$INSTALL_YAML" "https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/install.yaml"
kubectl apply --server-side --force-conflicts -f "$INSTALL_YAML" >/dev/null
for d in kyverno-admission-controller kyverno-background-controller kyverno-cleanup-controller kyverno-reports-controller; do
  kubectl -n "$KYVERNO_NS" rollout status "deploy/$d" --timeout=300s >/dev/null
  kubectl -n "$KYVERNO_NS" scale "deploy/$d" --replicas="$KYVERNO_REPLICAS" >/dev/null
done
log_ok "Kyverno ${KYVERNO_VERSION} running (replicas=${KYVERNO_REPLICAS})"

# --- platform CA trust for cosign verification (internal-ca mode) -------------
if [[ "${TLS_MODE:-internal-ca}" == "internal-ca" ]]; then
  CA_FILE="$ROOT_DIR/reverse-proxy/certificates/ca.crt"
  [[ -f "$CA_FILE" ]] || die "platform CA missing ($CA_FILE) — run scripts/bootstrap.sh"
  kubectl -n "$KYVERNO_NS" create configmap platform-ca --from-file=ca.crt="$CA_FILE" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$KYVERNO_NS" patch deploy kyverno-admission-controller --type=strategic -p '{
    "spec": {"template": {"spec": {
      "volumes": [{"name": "platform-ca", "configMap": {"name": "platform-ca"}}],
      "containers": [{"name": "kyverno",
        "volumeMounts": [{"name": "platform-ca", "mountPath": "/platform-ca", "readOnly": true}],
        "env": [{"name": "SSL_CERT_FILE", "value": "/platform-ca/ca.crt"}]}]
    }}}}' >/dev/null
  kubectl -n "$KYVERNO_NS" rollout status deploy/kyverno-admission-controller --timeout=180s >/dev/null
  log_ok "platform CA mounted into kyverno-admission-controller (SSL_CERT_FILE)"
fi

# --- policies -----------------------------------------------------------------
"$SCRIPT_DIR/cosign-public-key.sh"     # verify-image-signature (key injected)

TMP_POL="$(mktemp)"
PLATFORM_DOMAIN="$PLATFORM_DOMAIN" envsubst '${PLATFORM_DOMAIN}' \
  < "$SCRIPT_DIR/policies/require-digest-pinning.yaml" > "$TMP_POL"
kubectl apply -f "$TMP_POL" >/dev/null
rm -f "$TMP_POL"
log_ok "policy require-digest-pinning applied (Enforce)"

cat <<EOF

Kyverno policies live:
  verify-image-signature  → cosign-signed images only (platform key)
  require-digest-pinning  → digest refs to registry.${PLATFORM_DOMAIN} only
Test after a deploy:  kubectl get clusterpolicy
Next: kubernetes/eso/install-eso.sh
EOF
