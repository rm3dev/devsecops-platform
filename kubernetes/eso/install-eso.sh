#!/usr/bin/env bash
# =============================================================================
# install-eso.sh — External Secrets Operator (pinned chart ${ESO_CHART_VERSION})
# + the platform ClusterSecretStore 'vault-cluster-store' pointing at Vault
# (https://vault.<domain>/v1, KV v2 'secret/', Kubernetes auth mount
# 'kubernetes-<cluster>' — configured by vault/scripts/30-k8s-auth.sh).
#
# Application secrets flow: charts values.secrets[] → ExternalSecret →
# Vault secret/data/apps/<service>/<name> → in-cluster Secret. NO secret
# values ever live in Git (master spec §11).
#
# Chart is pulled from ghcr.io by helm ON THIS HOST (admin hosts have internet
# during bootstrap — same trust model as the NVD mirror / trivy DB scripts).
# Idempotent. Requires: helm, kubectl, yq.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
load_env
require_cmd kubectl helm yq

ESO_CHART_VERSION="${ESO_CHART_VERSION:-2.14.0}"
ESO_NS=external-secrets
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_CLUSTER_NAME="${K8S_CLUSTER_NAME:-lab-k3s}"

if [[ -z "${KUBECONFIG:-}" && -f /etc/rancher/k3s/k3s.yaml ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi
kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster (KUBECONFIG=${KUBECONFIG:-unset})"

log_info "installing External Secrets Operator (chart ${ESO_CHART_VERSION})…"
kubectl apply -f "$ROOT_DIR/kubernetes/namespaces.yaml" >/dev/null
helm upgrade --install external-secrets \
  oci://ghcr.io/external-secrets/charts/external-secrets \
  --version "$ESO_CHART_VERSION" \
  -n "$ESO_NS" \
  --set installCRDs=true \
  --wait --timeout 5m >/dev/null
log_ok "ESO ${ESO_CHART_VERSION} running"

# --- service account the ClusterSecretStore assumes (Vault k8s auth role
#     'eso-reader' is bound to exactly this SA/ns — vault/scripts/30-) --------
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eso-vault-auth
  namespace: external-secrets
  labels:
    app.kubernetes.io/part-of: external-secrets
EOF

# --- ClusterSecretStore (templated: domain, auth mount, CA for internal TLS) --
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
PLATFORM_DOMAIN="$PLATFORM_DOMAIN" K8S_CLUSTER_NAME="$K8S_CLUSTER_NAME" \
  envsubst '${PLATFORM_DOMAIN},${K8S_CLUSTER_NAME}' \
  < "$SCRIPT_DIR/cluster-secret-store.yaml.tpl" > "$TMP"
if [[ "${TLS_MODE:-internal-ca}" == "internal-ca" ]]; then
  CA_FILE="$ROOT_DIR/reverse-proxy/certificates/ca.crt"
  [[ -f "$CA_FILE" ]] || die "platform CA missing ($CA_FILE) — run scripts/bootstrap.sh"
  CA_B64="$(base64 -w0 < "$CA_FILE")" yq -i '.spec.provider.vault.caBundle = strenv(CA_B64)' "$TMP"
else
  yq -i 'del(.spec.provider.vault.caBundle)' "$TMP"
fi
kubectl apply -f "$TMP" >/dev/null
log_ok "ClusterSecretStore vault-cluster-store applied (server https://vault.${PLATFORM_DOMAIN}, auth mount kubernetes-${K8S_CLUSTER_NAME})"

cat <<EOF

Next:  vault/scripts/30-k8s-auth.sh    (Vault side: auth mount, policy, role)
Check: kubectl get clustersecretstore vault-cluster-store -o yaml | grep -A3 conditions
       (becomes Ready only AFTER the Vault side is configured)
EOF
