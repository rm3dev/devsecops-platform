#!/usr/bin/env bash
# =============================================================================
# 10-register-cluster.sh — multi-cluster support (master spec §12).
#
# Registers an ADDITIONAL cluster (Option A: any reachable cluster) with the
# ArgoCD instance installed by argocd/install-argocd.sh:
#   ./10-register-cluster.sh <name> <kubectl-context> [env-label]
#
# Creates the standard argocd-manager SA/ClusterRoleBinding on the target
# cluster (that is what `argocd cluster add` does) and records it in ArgoCD.
# Afterwards, to actually schedule work there:
#   1. argocd cluster list → note the SERVER URL of <name>
#   2. in gitops-repository: copy clusters/<env>/ → clusters/<env>-<name>/,
#      set destinations.server to that URL and rename AppProject/ApplicationSet
#      (e.g. prod-eu2 / prod-eu2-apps); adjust namespace patterns if needed
#   3. the platform-root app-of-apps syncs it — no ArgoCD restart required
#
# Requires: argocd CLI (logged-in admin creds come from secrets/argocd.env),
# kubectl with the target context available.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
load_env
require_cmd kubectl

NAME="${1:?usage: 10-register-cluster.sh <name> <kubectl-context>}"
CONTEXT="${2:?usage: 10-register-cluster.sh <name> <kubectl-context>}"
ARGOCD_ENV="$ROOT_DIR/secrets/argocd.env"

command -v argocd >/dev/null || die "argocd CLI missing on host (see kubernetes/README.md prerequisites)"
[[ -f "$ARGOCD_ENV" ]] || die "secrets/argocd.env missing — run kubernetes/argocd/install-argocd.sh first"
set -a; source "$ARGOCD_ENV"; set +a
[[ "${ARGOCD_ADMIN_PASSWORD:-}" != "" ]] || die "ARGOCD_ADMIN_PASSWORD missing in secrets/argocd.env"
[[ -n "${ARGOCD_SERVER_URL:-}" ]]    || die "ARGOCD_SERVER_URL missing in secrets/argocd.env"

kubectl --context "$CONTEXT" cluster-info >/dev/null 2>&1 \
  || die "kubectl context '${CONTEXT}' unreachable — check your kubeconfig"
log_info "target cluster '${CONTEXT}' reachable"

argocd login "${ARGOCD_SERVER_URL#https://}" --insecure --grpc-web \
  --username "${ARGOCD_ADMIN_USER:-admin}" --password "$ARGOCD_ADMIN_PASSWORD" >/dev/null \
  || die "cannot log in to ArgoCD at ${ARGOCD_SERVER_URL} (stale admin password in secrets/argocd.env?)"

argocd cluster add "$CONTEXT" --name "$NAME" --upsert \
  || die "argocd cluster add failed for context '${CONTEXT}'"
log_ok "cluster '${NAME}' registered in ArgoCD"
argocd cluster list

cat <<EOF

Cluster '${NAME}' registered. To schedule workloads there, follow the header
steps (copy clusters/<env>/ → clusters/<env>-${NAME}/ in the gitops-repository
with the SERVER URL shown above).
EOF
