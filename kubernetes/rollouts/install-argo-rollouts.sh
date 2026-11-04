#!/usr/bin/env bash
# =============================================================================
# install-argo-rollouts.sh — Argo Rollouts (progressive delivery, Phase 9,
# D-30), pinned v${ARGO_ROLLOUTS_VERSION}.
#
# The microservice-standard chart renders an argoproj.io/v1alpha1 Rollout
# INSTEAD of a Deployment when applications/<svc>/values.yaml sets
# rollout.enabled=true (canary or blue-green). ArgoCD knows Rollout health
# natively; verifyDeployment polls .status.phase with the read-only kubeconfig
# (argoproj.io get/list/watch was added to its ClusterRole in Phase 9).
#
# Lab clusters are single-node: replicas scaled to
# ${ARGO_ROLLOUTS_REPLICAS:-1} (install.yaml ships HA=2). Set 2 on real clusters.
# Idempotent. Requires: kubectl. Images come from quay.io → mirrored through
# registry.<domain> by the node's registries.yaml (D-27).
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
load_env
require_cmd kubectl curl

ARGO_ROLLOUTS_VERSION="${ARGO_ROLLOUTS_VERSION:-v1.10.1}"
ARGO_ROLLOUTS_REPLICAS="${ARGO_ROLLOUTS_REPLICAS:-1}"
RO_NS=argo-rollouts

if [[ -z "${KUBECONFIG:-}" && -f /etc/rancher/k3s/k3s.yaml ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi
kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster (KUBECONFIG=${KUBECONFIG:-unset})"

log_info "installing Argo Rollouts ${ARGO_ROLLOUTS_VERSION}…"
INSTALL_YAML="$(mktemp)"; trap 'rm -f "$INSTALL_YAML"' EXIT
curl --retry 3 --retry-delay 2 -fsSL -o "$INSTALL_YAML" \
  "https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_ROLLOUTS_VERSION}/install.yaml"
# integrity guard: a truncated download applies a partial bundle and exits 0
# (live incident: Deployment is the LAST doc — it silently vanished)
grep -q "^kind: Deployment" "$INSTALL_YAML" \
  || die "rollouts install.yaml looks truncated (no Deployment) — re-run; check egress to github.com"
# upstream install.yaml carries NO Namespace object (live failure:
# "namespaces argo-rollouts not found") — create it first, idempotently.
kubectl create namespace "$RO_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply --server-side --force-conflicts -f "$INSTALL_YAML" >/dev/null
kubectl -n "$RO_NS" rollout status deploy/argo-rollouts --timeout=300s >/dev/null
kubectl -n "$RO_NS" scale deploy/argo-rollouts --replicas="$ARGO_ROLLOUTS_REPLICAS" >/dev/null
log_ok "Argo Rollouts ${ARGO_ROLLOUTS_VERSION} running (replicas=${ARGO_ROLLOUTS_REPLICAS})"

cat <<EOF

Rollout CRDs live: kubectl get crd rollouts.argoproj.io
Apps opt in via values.yaml → rollout.enabled: true (see chart + orders-api).
Remember: rollout-enabled overlays need replicas-config.yaml (configurations:)
and JSON6902 patches for pod-template LIST edits — see gitops.md §9.
EOF
