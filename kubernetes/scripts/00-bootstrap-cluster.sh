#!/usr/bin/env bash
# =============================================================================
# 00-bootstrap-cluster.sh — ordered deployment-plane bootstrap (Phase 8).
#
#   1. preflight  (platform secrets ready, tooling present)
#   2. K3s        (Option B lab cluster — skip with SKIP_K3S=1 for Option A;
#                  needs root: sudo SKIP_K3S=… $0 or run whole script via sudo)
#   3. ArgoCD     (pinned install, NodePort, jenkins-cd token, root app-of-apps)
#   4. Kyverno    (pinned install + verify-image-signature + digest pinning)
#   4b. Rollouts  (pinned Argo Rollouts — progressive delivery, Phase 9)
#   5. ESO        (pinned chart + ClusterSecretStore → Vault)
#   6. Vault k8s  (auth mount, policy, role, demo secret, e2e login check)
#   7. kubeconfig (read-only verifier identity → secrets/k8s.env, Phase 9)
#
# Prerequisites (checked below, each with the exact fix):
#   * Docker Compose platform running (gitlab, vault unsealed, nexus configured)
#   * gitlab/scripts/run-all.sh done  → real GITOPS_REPO_TOKEN
#   * security/scripts/10-cosign-keys.sh done → cosign.pub
#   * secrets/vault-root.env (or VAULT_ROOT_TOKEN exported)
#   * host tools: kubectl(after step 2), helm, yq, argocd CLI, jq  (see README)
#
# Idempotent end-to-end: every step is safe to re-run.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
load_env
KDIR="$ROOT_DIR/kubernetes"

SKIP_K3S="${SKIP_K3S:-0}"

# --- 1. preflight --------------------------------------------------------------
log_info "preflight checks…"
require_cmd jq helm yq curl
command -v argocd >/dev/null || die "argocd CLI missing on host — see kubernetes/README.md (pinned download one-liner)"

[[ -f "$ROOT_DIR/secrets/gitlab-jenkins.env" ]] && { set -a; source "$ROOT_DIR/secrets/gitlab-jenkins.env"; set +a; }
[[ "${GITOPS_REPO_TOKEN:-SET_IN_PHASE_8}" != "SET_IN_PHASE_8" ]] \
  || die "GITOPS_REPO_TOKEN placeholder — run: gitlab/scripts/50-gitops-repository.sh"
[[ "${NEXUS_DEPLOY_PASSWORD:-SET_IN_PHASE_5}" != "SET_IN_PHASE_5" ]] \
  || die "NEXUS_DEPLOY_PASSWORD placeholder — run: nexus/scripts/run-all.sh (Phase 5)"
[[ -s "$ROOT_DIR/secrets/cosign/cosign.pub" ]] \
  || die "secrets/cosign/cosign.pub missing — run: security/scripts/10-cosign-keys.sh"
if [[ -z "${VAULT_ROOT_TOKEN:-}" && -f "$ROOT_DIR/secrets/vault-root.env" ]]; then
  set -a; source "$ROOT_DIR/secrets/vault-root.env"; set +a
fi
[[ -n "${VAULT_ROOT_TOKEN:-}" ]] \
  || die "VAULT_ROOT_TOKEN unavailable — export it or write secrets/vault-root.env (from 'vault operator init')"
log_ok "preflight passed"

# --- 2. K3s (Option B) -----------------------------------------------------------
if [[ "$SKIP_K3S" != "1" ]]; then
  [[ $EUID -eq 0 ]] || die "K3s install needs root — re-run: sudo SKIP_K3S=$SKIP_K3S $0   (or SKIP_K3S=1 for an existing cluster)"
  "$KDIR/k3s/install-k3s.sh"
else
  log_info "SKIP_K3S=1 — using the existing cluster from the current kubectl context (Option A)"
fi
if [[ -z "${KUBECONFIG:-}" && -f /etc/rancher/k3s/k3s.yaml ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi
require_cmd kubectl
kubectl cluster-info >/dev/null 2>&1 || die "no reachable cluster — run step 2 (K3s) or fix KUBECONFIG"

# --- 3–7. platform services -------------------------------------------------------
"$KDIR/argocd/install-argocd.sh"
"$KDIR/kyverno/install-kyverno.sh"
"$KDIR/rollouts/install-argo-rollouts.sh"
"$KDIR/eso/install-eso.sh"
"$ROOT_DIR/vault/scripts/30-k8s-auth.sh"
"$KDIR/scripts/20-verify-kubeconfig.sh"

# --- summary ------------------------------------------------------------------------
cat <<EOF

===============================================================================
Deployment plane READY (cluster: ${K8S_CLUSTER_NAME:-lab-k3s})
  ArgoCD   $(grep -E '^ARGOCD_SERVER_URL=' "$ROOT_DIR/secrets/argocd.env" | cut -d= -f2-)
  Policies verify-image-signature, require-digest-pinning (Enforce)
  Secrets  ESO → vault-cluster-store → Vault KV v2 secret/apps/*

Finish on the CI plane:
  1. gitlab/scripts/50-gitops-repository.sh      (if not run yet: gitops content + token)
  2. docker compose up -d jenkins agent-general  (picks up secrets/argocd.env + k8s.env)
  3. push a service build on main → stages GitOps & Deploy go live (flags already ON)
  4. promote: Jenkins → platform/gitops-promotion (dev→qa→uat→prod)
===============================================================================
EOF
