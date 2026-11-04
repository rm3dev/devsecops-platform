#!/usr/bin/env bash
# =============================================================================
# install-argocd.sh — pinned ArgoCD (install.yaml v${ARGOCD_VERSION}) +
# platform wiring (architecture D-27):
#   * NodePort ${ARGOCD_NODEPORT:-30443} (K3s has no ingress controller —
#     traefik/servicelb are disabled so the platform Traefik keeps :443).
#   * local account 'jenkins-cd': API key ONLY, RBAC-limited to
#     applications get/sync in projects dev|qa|uat|prod — Jenkins can ask
#     ArgoCD to sync and read status, NOTHING else (no cluster admin, ever).
#   * repo trust: platform CA for gitlab.<domain> (TLS_MODE=internal-ca) +
#     private repo credentials (jenkins-ci / GITOPS_REPO_TOKEN).
#   * root app-of-apps (root-app.yaml) → clusters/ → AppProjects +
#     ApplicationSets → one Application per applications/*/overlays/<env>.
#
# Writes secrets/argocd.env (ARGOCD_SERVER_URL / ARGOCD_AUTH_TOKEN /
# ARGOCD_OPTS / ARGOCD_ADMIN_*) consumed by jenkins + agent-general
# (deployApplication uses the argocd CLI with these env vars natively).
#
# Idempotent. Requires: kubectl, argocd CLI (v${ARGOCD_VERSION} — same pin as
# agent-general: curl -fsSL -o /usr/local/bin/argocd
# https://github.com/argoproj/argo-cd/releases/download/v3.4.8/argocd-linux-amd64)
# Prereq: gitlab/scripts/50-gitops-repository.sh (real GITOPS_REPO_TOKEN).
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
load_env
require_cmd kubectl curl jq

ARGOCD_VERSION="${ARGOCD_VERSION:-v3.4.8}"
ARGOCD_NODEPORT="${ARGOCD_NODEPORT:-30443}"
K8S_CLUSTER_NAME="${K8S_CLUSTER_NAME:-lab-k3s}"
ARGOCD_NS=argocd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGOCD_ENV="$ROOT_DIR/secrets/argocd.env"

command -v argocd >/dev/null || die "argocd CLI missing on host — see header comment for the pinned download one-liner"

# secrets: GITOPS_REPO_TOKEN must be real (gitlab/scripts/50-gitops-repository.sh)
[[ -f "$ROOT_DIR/secrets/gitlab-jenkins.env" ]] && { set -a; source "$ROOT_DIR/secrets/gitlab-jenkins.env"; set +a; }
[[ "${GITOPS_REPO_TOKEN:-SET_IN_PHASE_8}" != "SET_IN_PHASE_8" ]] \
  || die "GITOPS_REPO_TOKEN is the placeholder — run gitlab/scripts/50-gitops-repository.sh first"

# KUBECONFIG: default to the K3s kubeconfig when present (Option B)
if [[ -z "${KUBECONFIG:-}" && -f /etc/rancher/k3s/k3s.yaml ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi
kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster (KUBECONFIG=${KUBECONFIG:-unset}) — run kubernetes/k3s/install-k3s.sh or point KUBECONFIG at your cluster"

HOST_IP="${PLATFORM_HOST_IP:-}"
if [[ -z "$HOST_IP" ]]; then
  HOST_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
fi
[[ -n "$HOST_IP" ]] || die "could not detect host IP — set PLATFORM_HOST_IP in .env"
ARGOCD_SERVER_URL="${ARGOCD_SERVER_URL_OVERRIDE:-https://${HOST_IP}:${ARGOCD_NODEPORT}}"
REPO_URL="https://gitlab.${PLATFORM_DOMAIN}/platform/gitops-repository.git"

# --- state from previous runs (token reuse — API tokens cannot be re-read) ---
OLD_ADMIN_PW="" ; OLD_TOKEN=""
if [[ -f "$ARGOCD_ENV" ]]; then
  # shellcheck disable=SC1090
  OLD_ADMIN_PW="$(grep -E '^ARGOCD_ADMIN_PASSWORD=' "$ARGOCD_ENV" | cut -d= -f2- || true)"
  OLD_TOKEN="$(grep -E '^ARGOCD_AUTH_TOKEN=' "$ARGOCD_ENV" | cut -d= -f2- || true)"
fi

log_info "installing ArgoCD ${ARGOCD_VERSION} (pinned manifests)…"
kubectl apply -f "$ROOT_DIR/kubernetes/namespaces.yaml" >/dev/null
INSTALL_YAML="$(mktemp)"
trap 'rm -f "$INSTALL_YAML"' EXIT
curl -fsSL -o "$INSTALL_YAML" "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
kubectl apply --server-side --force-conflicts -n "$ARGOCD_NS" -f "$INSTALL_YAML" >/dev/null

log_info "waiting for ArgoCD rollouts…"
for d in argocd-server argocd-repo-server argocd-applicationset-controller argocd-notifications-controller argocd-redis; do
  kubectl -n "$ARGOCD_NS" rollout status "deploy/$d" --timeout=300s >/dev/null
done
kubectl -n "$ARGOCD_NS" rollout status statefulset/argocd-application-controller --timeout=300s >/dev/null
log_ok "ArgoCD ${ARGOCD_VERSION} running"

# --- exposure: NodePort (lab; Option A overrides ARGOCD_SERVER_URL_OVERRIDE) --
kubectl -n "$ARGOCD_NS" patch svc argocd-server --type merge -p \
  "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"name\":\"https\",\"port\":443,\"targetPort\":8080,\"nodePort\":${ARGOCD_NODEPORT}}]}}" >/dev/null
log_ok "argocd-server exposed as NodePort ${ARGOCD_NODEPORT} → ${ARGOCD_SERVER_URL}"

# --- settings: url + jenkins-cd account + least-privilege RBAC ---------------
kubectl -n "$ARGOCD_NS" patch cm argocd-cm --type merge -p \
  "$(jq -n --arg url "$ARGOCD_SERVER_URL" '{data:{url:$url, "accounts.jenkins-cd":"apiKey"}}')" >/dev/null

RBAC_CSV="p, role:jenkins-cd, applications, get, dev/*, allow
p, role:jenkins-cd, applications, sync, dev/*, allow
p, role:jenkins-cd, applications, get, qa/*, allow
p, role:jenkins-cd, applications, sync, qa/*, allow
p, role:jenkins-cd, applications, get, uat/*, allow
p, role:jenkins-cd, applications, sync, uat/*, allow
p, role:jenkins-cd, applications, get, prod/*, allow
p, role:jenkins-cd, applications, sync, prod/*, allow
g, jenkins-cd, role:jenkins-cd"
kubectl -n "$ARGOCD_NS" patch cm argocd-rbac-cm --type merge -p \
  "$(jq -n --arg csv "$RBAC_CSV" '{data:{"policy.default":"role:readonly","policy.csv":$csv}}')" >/dev/null
log_ok "jenkins-cd account: applications get/sync in dev|qa|uat|prod only (default: readonly)"

# --- admin login (rotate the published initial password on first run) --------
login_argocd() { # password
  argocd login "${ARGOCD_SERVER_URL#https://}" --insecure --grpc-web \
    --username admin --password "$1" >/dev/null 2>&1
}
ADMIN_PW="$OLD_ADMIN_PW"
if [[ -z "$ADMIN_PW" ]] || ! login_argocd "$ADMIN_PW"; then
  log_info "reading argocd-initial-admin-secret…"
  deadline=$(( $(date +%s) + 120 )); ADMIN_PW=""
  while [[ -z "$ADMIN_PW" ]]; do
    ADMIN_PW="$(kubectl -n "$ARGOCD_NS" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
    [[ -n "$ADMIN_PW" ]] || { [[ $(date +%s) -lt $deadline ]] || die "initial admin secret never appeared"; sleep 5; }
  done
  # Retry loop: server can lag a few seconds past rollout-Ready (TLS/gRPC init).
  # Surface the real CLI error on final failure — and note the hash-mismatch
  # recovery (admin.password null + restart re-derives it from the initial secret).
  LOGIN_OK=0; LOGIN_ERR=""
  for _ in $(seq 1 10); do
    LOGIN_ERR="$(argocd login "${ARGOCD_SERVER_URL#https://}" --insecure --grpc-web --username admin --password "$ADMIN_PW" 2>&1)" && { LOGIN_OK=1; break; }
    sleep 6
  done
  [[ "$LOGIN_OK" == "1" ]] || die "cannot log in to ArgoCD as admin — argocd said: ${LOGIN_ERR} — if Unauthenticated persists, the admin hash and initial secret disagree; recover with: kubectl -n ${ARGOCD_NS} patch secret argocd-secret --type merge -p {data:{admin.password:null,admin.passwordMtime:null}} && kubectl -n ${ARGOCD_NS} rollout restart deploy/argocd-server, then re-run"
  NEW_PW="$(gen_secret)"
  if argocd account update-password --account admin --current-password "$ADMIN_PW" --new-password "$NEW_PW" >/dev/null 2>&1; then
    ADMIN_PW="$NEW_PW"; log_ok "admin password rotated (→ secrets/argocd.env)"
    # persist immediately — if any later step dies, the rotated password
    # survives in argocd.env and the next run logs in with it (the final
    # cat > rewrite is idempotent with this value).
    append_secret "$ARGOCD_ENV" "ARGOCD_ADMIN_PASSWORD=${ADMIN_PW}"
  else
    log_warn "admin password rotation failed (already rotated?) — keeping current password"
  fi
fi

# --- jenkins-cd API token (generate once; cannot be re-read) -----------------
if [[ -n "$OLD_TOKEN" && "$OLD_TOKEN" != "SET_IN_PHASE_8" ]]; then
  ARGO_TOKEN="$OLD_TOKEN"; log_ok "reusing jenkins-cd token from secrets/argocd.env"
else
  ARGO_TOKEN="$(argocd account generate-token --account jenkins-cd)"
  [[ -n "$ARGO_TOKEN" ]] || die "failed to generate jenkins-cd token"
  log_ok "jenkins-cd API token generated"
  # persist immediately — tokens cannot be re-read; losing this to a later
  # mid-script death means generating yet another one on the next run.
  append_secret "$ARGOCD_ENV" "ARGOCD_AUTH_TOKEN=${ARGO_TOKEN}"
fi

# --- git trust: platform CA (internal-ca) + private repo credentials ---------
if [[ "${TLS_MODE:-internal-ca}" == "internal-ca" ]]; then
  CA_FILE="$ROOT_DIR/reverse-proxy/certificates/ca.crt"
  [[ -f "$CA_FILE" ]] || die "platform CA missing ($CA_FILE) — run scripts/bootstrap.sh"
  if argocd cert list 2>/dev/null | grep -q "gitlab.${PLATFORM_DOMAIN}"; then
    log_ok "git TLS trust for gitlab.${PLATFORM_DOMAIN} already present"
  else
    argocd cert add-git --host "gitlab.${PLATFORM_DOMAIN}" --from-file "$CA_FILE" >/dev/null
    log_ok "platform CA registered for gitlab.${PLATFORM_DOMAIN}"
  fi
fi
# re-add the repo every run: keeps credentials in sync with token rotation.
# Prefer the read-only 'argocd' GitLab identity (gitlab/scripts/50- provisions
# ARGOCD_GIT_TOKEN); fall back to the CI write token only if absent.
REPO_USER=jenkins-ci; REPO_TOKEN="$GITOPS_REPO_TOKEN"
if [[ -n "${ARGOCD_GIT_TOKEN:-}" && "${ARGOCD_GIT_TOKEN}" != "SET_IN_PHASE_8" ]]; then
  REPO_USER=argocd; REPO_TOKEN="$ARGOCD_GIT_TOKEN"
fi
argocd repo rm "$REPO_URL" --hard >/dev/null 2>&1 || true
argocd repo add "$REPO_URL" --username "$REPO_USER" --password "$REPO_TOKEN" >/dev/null \
  || die "argocd repo add failed (user ${REPO_USER}) — is the token valid and gitlab.${PLATFORM_DOMAIN} reachable/trusted from this host?"
log_ok "gitops-repository registered in ArgoCD as user '${REPO_USER}' (connection validated)"

# --- root app-of-apps ---------------------------------------------------------
PLATFORM_DOMAIN="$PLATFORM_DOMAIN" envsubst '${PLATFORM_DOMAIN}' < "$SCRIPT_DIR/root-app.yaml" | kubectl apply -f - >/dev/null
log_info "waiting for platform-root (app-of-apps → clusters/)…"
argocd app wait platform-root --sync --health --timeout 300 >/dev/null \
  || { argocd app get platform-root || true; die "platform-root did not become healthy — inspect: argocd app get platform-root"; }
log_ok "platform-root healthy — AppProjects + ApplicationSets for dev|qa|uat|prod are live"

# --- persist consumer env -----------------------------------------------------
umask 077
cat > "$ARGOCD_ENV" <<EOF
# Written by kubernetes/argocd/install-argocd.sh — consumed by jenkins +
# agent-general (compose env_file). ARGOCD_OPTS=--insecure matches the lab
# NodePort self-signed cert; for Option A with a trusted certificate, clear it.
ARGOCD_SERVER_URL=${ARGOCD_SERVER_URL}
ARGOCD_AUTH_TOKEN=${ARGO_TOKEN}
ARGOCD_OPTS=--insecure
ARGOCD_ADMIN_USER=admin
ARGOCD_ADMIN_PASSWORD=${ADMIN_PW}
K8S_CLUSTER_NAME=${K8S_CLUSTER_NAME}
EOF
log_ok "secrets/argocd.env written"

cat <<EOF

ArgoCD UI:  ${ARGOCD_SERVER_URL}   (admin / see secrets/argocd.env)
Next:       kubernetes/kyverno/install-kyverno.sh
            kubernetes/eso/install-eso.sh
            vault/scripts/30-k8s-auth.sh
            kubernetes/scripts/20-verify-kubeconfig.sh
        …or simply: kubernetes/scripts/00-bootstrap-cluster.sh
Then:       docker compose up -d jenkins agent-general   (picks up argocd.env)
EOF
