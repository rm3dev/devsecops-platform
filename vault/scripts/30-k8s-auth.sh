#!/usr/bin/env bash
# =============================================================================
# 30-k8s-auth.sh — Vault side of the External Secrets Operator chain (Phase 8).
#
# Wires Kubernetes auth so ESO (SA external-secrets:eso-vault-auth) can read
# application secrets WITHOUT any static Vault token in the cluster:
#   1. SA vault-token-reviewer + system:auth-delegator binding → Vault
#      validates pod tokens via TokenReview against the cluster API.
#   2. auth enable kubernetes-<K8S_CLUSTER_NAME> (one mount per cluster —
#      multi-cluster: rerun with a different K8S_CLUSTER_NAME/KUBECONFIG).
#   3. KV v2 at 'secret/' + policy eso-app-secrets (read apps/* ONLY) +
#      role 'eso-reader' bound to the exact SA/namespace.
#   4. Seeds the demo secret for the gitops-repository sample app
#      (secret/apps/orders-api/db-creds) if absent — lab convenience,
#      ROTATE before anything real depends on it.
#   5. Verifies end-to-end: a real eso-vault-auth token logs in via the mount.
#
# Requires: kubectl (cluster reachable), jq, docker compose (vault container
# running + UNSEALED), and VAULT_ROOT_TOKEN — export it or place it in
# secrets/vault-root.env (from `vault operator init`, see bootstrap §Vault).
# Lab reachability: Vault talks to https://<host-ip>:6443 (K3s API) and ESO
# talks to https://vault.<domain> (node /etc/hosts + platform CA — both set up
# by kubernetes/k3s/install-k3s.sh + kubernetes/eso/install-eso.sh).
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
load_env
require_cmd kubectl jq

K8S_CLUSTER_NAME="${K8S_CLUSTER_NAME:-lab-k3s}"
AUTH_PATH="kubernetes-${K8S_CLUSTER_NAME}"
ESO_NS=external-secrets

# --- root token ----------------------------------------------------------------
if [[ -z "${VAULT_ROOT_TOKEN:-}" && -f "$ROOT_DIR/secrets/vault-root.env" ]]; then
  set -a; source "$ROOT_DIR/secrets/vault-root.env"; set +a
fi
[[ -n "${VAULT_ROOT_TOKEN:-}" ]] || die "VAULT_ROOT_TOKEN not set — export it or write secrets/vault-root.env (value from 'vault operator init'; see installation.md §Vault)"

vx() { # vault CLI inside the container with the root token
  ( cd "$ROOT_DIR" && docker compose -f docker-compose.yml exec -T -e VAULT_TOKEN="$VAULT_ROOT_TOKEN" vault vault "$@" )
}

vx status -format=json 2>/dev/null | jq -e '.sealed == false' >/dev/null \
  || die "vault is sealed/unreachable — unseal it first (docker compose exec vault vault operator unseal …)"
log_ok "vault unsealed and root token accepted"

# --- cluster API coordinates ----------------------------------------------------
if [[ -z "${KUBECONFIG:-}" && -f /etc/rancher/k3s/k3s.yaml ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi
kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach the cluster"
kubectl get ns "$ESO_NS" >/dev/null 2>&1 || die "namespace $ESO_NS missing — run kubernetes/eso/install-eso.sh first"

HOST_IP="${PLATFORM_HOST_IP:-}"
if [[ -z "$HOST_IP" ]]; then
  HOST_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
fi
[[ -n "$HOST_IP" ]] || die "could not detect host IP — set PLATFORM_HOST_IP in .env"
KUBE_API_URL="${KUBE_API_URL:-https://${HOST_IP}:6443}"
K8S_API_CA_FILE="${K8S_API_CA_FILE:-/var/lib/rancher/k3s/server/tls/server-ca.crt}"
[[ -f "$K8S_API_CA_FILE" ]] || die "cluster API CA not found ($K8S_API_CA_FILE) — for existing clusters set K8S_API_CA_FILE in the environment"

# --- TokenReview identity ---------------------------------------------------------
log_info "creating SA vault-token-reviewer (+ system:auth-delegator binding)…"
kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-token-reviewer
  namespace: ${ESO_NS}
---
apiVersion: v1
kind: Secret
metadata:
  name: vault-token-reviewer-token
  namespace: ${ESO_NS}
  annotations:
    kubernetes.io/service-account.name: vault-token-reviewer
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-token-reviewer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: vault-token-reviewer
    namespace: ${ESO_NS}
EOF
REVIEWER_TOKEN=""
deadline=$(( $(date +%s) + 60 ))
while [[ -z "$REVIEWER_TOKEN" ]]; do
  REVIEWER_TOKEN="$(kubectl -n "$ESO_NS" get secret vault-token-reviewer-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  [[ -n "$REVIEWER_TOKEN" ]] || { [[ $(date +%s) -lt $deadline ]] || die "reviewer token secret was not populated"; sleep 3; }
done
log_ok "token-reviewer SA ready"

# --- Vault: auth mount + config ----------------------------------------------------
if vx auth list -format=json | jq -e --arg p "${AUTH_PATH}/" '.[$p]' >/dev/null 2>&1; then
  log_ok "auth mount ${AUTH_PATH} exists"
else
  vx auth enable -path="$AUTH_PATH" kubernetes >/dev/null
  log_info "auth mount ${AUTH_PATH} enabled"
fi
( cd "$ROOT_DIR" && docker compose -f docker-compose.yml cp "$K8S_API_CA_FILE" vault:/tmp/k8s-ca.crt >/dev/null )
vx write "auth/${AUTH_PATH}/config" \
  kubernetes_host="$KUBE_API_URL" \
  token_reviewer_jwt="$REVIEWER_TOKEN" \
  kubernetes_ca_cert=@/tmp/k8s-ca.crt \
  disable_iss_validation=true >/dev/null
log_ok "auth/${AUTH_PATH} → ${KUBE_API_URL} (TokenReview via vault-token-reviewer)"

# --- Vault: KV v2 + policy + role ---------------------------------------------------
if vx secrets list -format=json | jq -e '."secret/"' >/dev/null 2>&1; then
  log_ok "KV v2 mount secret/ exists"
else
  vx secrets enable -path=secret -version=2 kv >/dev/null
  log_info "KV v2 enabled at secret/"
fi
vx policy write eso-app-secrets - < "$ROOT_DIR/vault/policies/eso-app-secrets.hcl" >/dev/null
vx write "auth/${AUTH_PATH}/role/eso-reader" \
  bound_service_account_names=eso-vault-auth \
  bound_service_account_namespaces="$ESO_NS" \
  policies=eso-app-secrets \
  ttl=1h >/dev/null
log_ok "role eso-reader → policy eso-app-secrets (secret/data/apps/* read-only)"

# --- demo secret for the seeded sample app -------------------------------------------
if vx kv metadata get secret/apps/orders-api/db-creds >/dev/null 2>&1; then
  log_ok "secret/apps/orders-api/db-creds exists (left untouched)"
else
  DEMO_PW="$(gen_secret)"
  vx kv put secret/apps/orders-api/db-creds username=orders password="$DEMO_PW" >/dev/null
  log_warn "seeded DEMO secret secret/apps/orders-api/db-creds (password: ${DEMO_PW}) — rotate before real use"
fi

# --- end-to-end verification -----------------------------------------------------------
ESO_TOKEN="$(kubectl create token eso-vault-auth -n "$ESO_NS" --duration=10m)"
if vx write "auth/${AUTH_PATH}/login" role=eso-reader jwt="$ESO_TOKEN" -format=json | jq -e '.auth.client_token' >/dev/null; then
  log_ok "VERIFIED: eso-vault-auth token logs in via auth/${AUTH_PATH} (role eso-reader)"
else
  die "ESO login through auth/${AUTH_PATH} FAILED — check: vault container reaches ${KUBE_API_URL}, CA file correct, role binding (eso-vault-auth/${ESO_NS})"
fi

cat <<EOF

Vault ↔ Kubernetes auth complete (cluster: ${K8S_CLUSTER_NAME}).
ESO ClusterSecretStore should turn Ready within ~1m:
  kubectl get clustersecretstore vault-cluster-store
Application secret convention (KV v2):  secret/apps/<service>/<name> → {key: value}
Next: kubernetes/scripts/20-verify-kubeconfig.sh
EOF
