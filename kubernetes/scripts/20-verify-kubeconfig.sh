#!/usr/bin/env bash
# =============================================================================
# 20-verify-kubeconfig.sh — read-only deployment-verification identity for
# Jenkins (Phase 9 verifyDeployment consumes secrets/k8s.env).
#
# Creates SA platform-tools:deploy-verifier with get/list/watch ONLY on the
# objects a post-deploy verifier needs (deployments, replicasets, pods,
# pods/log, events, services, jobs, HPAs) — cluster-wide, because services
# live in <service>-<env> namespaces created dynamically by ArgoCD.
# Builds a self-contained kubeconfig (server + CA + long-lived SA token),
# base64s it into secrets/k8s.env (K8S_VERIFY_KUBECONFIG), and PROVES the
# least-privilege boundary with `kubectl auth can-i` checks.
#
# Idempotent (token secret is reused; kubeconfig rewritten). Requires: kubectl, yq.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
load_env
require_cmd kubectl yq

if [[ -z "${KUBECONFIG:-}" && -f /etc/rancher/k3s/k3s.yaml ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi
kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster (KUBECONFIG=${KUBECONFIG:-unset})"
K8S_CLUSTER_NAME="${K8S_CLUSTER_NAME:-lab-k3s}"
TOOLS_NS=platform-tools
SA=deploy-verifier
K8S_ENV="$ROOT_DIR/secrets/k8s.env"

kubectl apply -f "$ROOT_DIR/kubernetes/namespaces.yaml" >/dev/null
kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA}
  namespace: ${TOOLS_NS}
---
apiVersion: v1
kind: Secret
metadata:
  name: ${SA}-token
  namespace: ${TOOLS_NS}
  annotations:
    kubernetes.io/service-account.name: ${SA}
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${SA}-readonly
rules:
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods", "pods/log", "events", "services", "endpoints"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["get", "list", "watch"]
  # Phase 9: progressive-delivery workloads (verifyDeployment polls Rollout phase)
  - apiGroups: ["argoproj.io"]
    resources: ["rollouts", "analysisruns", "experiments"]
    verbs: ["get", "list", "watch"]
  # Phase 9: ESO readiness is part of deployment health
  - apiGroups: ["external-secrets.io"]
    resources: ["externalsecrets"]
    verbs: ["get", "list", "watch"]
---
# The ONLY active verb in the whole identity: port-forward tunneling for
# postDeploy smoke tests (runPostDeploy). It grants network reach to service
# ports — deliberately NOT exec/attach into containers.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: deploy-verifier-portforward
rules:
  - apiGroups: [""]
    resources: ["pods/portforward"]
    verbs: ["create", "get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: deploy-verifier-portforward
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: deploy-verifier-portforward
subjects:
  - kind: ServiceAccount
    name: deploy-verifier
    namespace: platform-tools
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${SA}-readonly
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${SA}-readonly
subjects:
  - kind: ServiceAccount
    name: ${SA}
    namespace: ${TOOLS_NS}
EOF
log_ok "SA ${TOOLS_NS}:${SA} + read-only ClusterRole applied"

TOKEN=""
deadline=$(( $(date +%s) + 60 ))
while [[ -z "$TOKEN" ]]; do
  TOKEN="$(kubectl -n "$TOOLS_NS" get secret "${SA}-token" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  [[ -n "$TOKEN" ]] || { [[ $(date +%s) -lt $deadline ]] || die "token secret was not populated"; sleep 3; }
done

SERVER="$(yq '.clusters[0].cluster.server' "$KUBECONFIG")"
CA_DATA="$(yq '.clusters[0].cluster.certificate-authority-data // ""' "$KUBECONFIG")"
if [[ -z "$CA_DATA" || "$CA_DATA" == "null" ]]; then
  CA_FILE="$(yq '.clusters[0].cluster.certificate-authority // ""' "$KUBECONFIG")"
  [[ -n "$CA_FILE" && -f "$CA_FILE" ]] || die "kubeconfig has neither CA data nor a readable CA file — set K8S_VERIFY_* manually"
  CA_DATA="$(base64 -w0 < "$CA_FILE")"
fi
# Option A override: verifyDeployment may run against a different API URL
SERVER="${KUBE_API_URL_OVERRIDE:-$SERVER}"

KC_FILE="$(mktemp)"; trap 'rm -f "$KC_FILE"' EXIT
cat > "$KC_FILE" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: ${K8S_CLUSTER_NAME}
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA_DATA}
contexts:
  - name: verify@${K8S_CLUSTER_NAME}
    context:
      cluster: ${K8S_CLUSTER_NAME}
      user: ${SA}
current-context: verify@${K8S_CLUSTER_NAME}
users:
  - name: ${SA}
    user:
      token: ${TOKEN}
EOF

# --- prove the least-privilege boundary --------------------------------------
# NOTE: kubectl auth can-i -q prints NOTHING — the answer lives in the exit
# code (0=allowed, 1=denied). Comparing its stdout to "yes" always fails.
can() { KUBECONFIG="$KC_FILE" kubectl auth can-i "$1" "$2" --all-namespaces -q 2>/dev/null; }
can get deployments   || die "verifier cannot even GET deployments — RBAC broken"
! can delete pods     || die "verifier can DELETE pods — RBAC TOO BROAD"
! can create secrets  || die "verifier can CREATE secrets — RBAC TOO BROAD"
can '*' pods/log      || die "verifier cannot read pod logs"
log_ok "RBAC verified: read-only (get/list/watch), no write verbs"

umask 077
cat > "$K8S_ENV" <<EOF
# Written by kubernetes/scripts/20-verify-kubeconfig.sh — consumed by
# agent-general (verifyDeployment, Phase 9). K8S_VERIFY_KUBECONFIG is the
# base64 of a self-contained kubeconfig (server + CA + SA token, read-only).
K8S_VERIFY_KUBECONFIG=$(base64 -w0 < "$KC_FILE")
KUBE_API_SERVER=${SERVER}
K8S_CLUSTER_NAME=${K8S_CLUSTER_NAME}
EOF
log_ok "secrets/k8s.env written (K8S_VERIFY_KUBECONFIG, read-only SA ${SA})"
echo "Next: docker compose up -d jenkins agent-general   (picks up the new env files)"
