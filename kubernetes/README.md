# Kubernetes deployment plane (Phase 8)

Everything needed to stand up and govern the cluster side of the platform.
The CI/CD control plane (Docker Compose) and the deployment plane (Kubernetes)
are separate: Jenkins **never** has cluster admin rights — it commits digests
to the gitops-repository and asks ArgoCD to sync (RBAC-limited token).

```
k3s/install-k3s.sh            Option B: pinned K3s lab cluster on the platform host
namespaces.yaml               argocd / kyverno / external-secrets
argocd/install-argocd.sh      pinned ArgoCD (install.yaml v3.4.8), NodePort, jenkins-cd
                              account + API token → secrets/argocd.env, repo TLS trust,
                              root app-of-apps → clusters/
argocd/root-app.yaml          TEMPLATED app-of-apps (envsubst at install)
kyverno/install-kyverno.sh    pinned Kyverno v1.19.2 + platform CA trust (internal-ca)
kyverno/policies/             verify-image-signature (cosign.pub from Phase 7),
                              require-digest-pinning (no mutable tags in workloads)
kyverno/cosign-public-key.sh  secrets/cosign/cosign.pub → kyverno ns secret
rollouts/install-argo-rollouts.sh  pinned Argo Rollouts v1.10.1 (Phase 9:
                              canary/blue-green via chart rollout.enabled)
eso/install-eso.sh            pinned External Secrets Operator (helm chart 2.14.0)
                              + ClusterSecretStore → Vault (kubernetes auth)
scripts/10-register-cluster.sh  multi-cluster / Option A: argocd cluster add
scripts/20-verify-kubeconfig.sh read-only SA kubeconfig → secrets/k8s.env (Phase 9)
scripts/00-bootstrap-cluster.sh ordered orchestrator for all of the above
clusters.yaml                 declarative cluster registry (name/api/environments)
```

## Host prerequisites

`kubectl`, `helm`, `yq`, `argocd` CLI (same pins as the agent images:
kubectl v1.35.10, helm v3.22.1, yq v4.54.1, argocd v3.4.8 — the
`install-argocd.sh` header prints download one-liners), plus root/sudo for
the K3s install (Option B only).

## Option B — lab cluster (default, D-01)

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml ./scripts/00-bootstrap-cluster.sh
```

Installs K3s **v1.36.5+k3s1** with traefik/servicelb DISABLED (the platform's
own Traefik owns host :80/:443 — see D-27), points containerd at the Nexus
registry (mirrors for docker.io/quay.io/ghcr.io + platform CA), adds
`/etc/hosts` entries for `*.<PLATFORM_DOMAIN>` (K3s propagates them to pod DNS
via NodeHosts), then installs ArgoCD/Kyverno/ESO and wires Vault k8s auth.

ArgoCD UI/API: `https://<host-ip>:30443` (NodePort, self-signed — UI shows a
cert warning by design; admin password → `secrets/argocd.env`).

## Option A — existing cluster

1. Point `kubectl` at the cluster (context with cluster-admin, once).
2. Set in `.env`: `K8S_CLUSTER_NAME`, `KUBE_API_URL`, `KUBE_API_CA_FILE`,
   `ARGOCD_SERVER_URL` (its future public URL), and ensure the cluster can
   resolve+trust `gitlab.<domain>`, `registry.<domain>`, `vault.<domain>`
   (DNS + CA distribution is your infrastructure's job).
3. `SKIP_K3S=1 ./scripts/00-bootstrap-cluster.sh`
4. Additional clusters: `./scripts/10-register-cluster.sh <name> <context>`.

## What lands where (secrets/)

| file | written by | consumed by |
|------|-----------|-------------|
| `argocd.env`  | argocd/install-argocd.sh | jenkins + agent-general (deployApplication) |
| `k8s.env`     | scripts/20-verify-kubeconfig.sh | agent-general (verifyDeployment, Phase 9) |
| `gitlab-jenkins.env` `GITOPS_REPO_TOKEN` | gitlab/scripts/50-gitops-repository.sh | jenkins (updateGitOps) |
