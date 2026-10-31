# GitOps & the Deployment Plane (Phase 8)

> Scope: how a green build becomes a running, signed, policy-checked workload —
> and how that workload is promoted, rolled back and kept secret-free.
> Decisions: D-26 (render & commit), D-27 (cluster exposure/mirroring),
> D-28 (admission control), D-29 (ESO/Vault secret flow).

## 1. Two planes, one direction of truth

```
CONTROL PLANE (Docker Compose host)          DEPLOYMENT PLANE (Kubernetes)
┌────────────────────────────────────┐       ┌─────────────────────────────────┐
│ GitLab ── service repos            │       │ ArgoCD (app-of-apps)            │
│        └─ platform/gitops-repository│◄──────┤   platform-root → clusters/     │
│ Jenkins ─ updateGitOps commits     │ pull  │   → AppProjects dev|qa|uat|prod │
│           deployApplication waits  │──────►│   → ApplicationSets → Apps      │
│ Nexus registry (signed digests)    │ pull  │ Kyverno (verify signature+digest)│
│ Vault (KV v2 apps/*)               │◄──────┤ ESO (ClusterSecretStore)        │
└────────────────────────────────────┘       └─────────────────────────────────┘
```

* **Git is the only deployment channel.** Jenkins never applies manifests and
  holds no cluster credential except the ArgoCD API token of local account
  `jenkins-cd`, whose RBAC is exactly: `applications get/sync` in projects
  `dev|qa|uat|prod`. Nothing else — no Kubernetes API access for deploys.
* **ArgoCD pulls** the gitops-repository (read-only GitLab identity `argocd`,
  PAT `argocd-read`) and reconciles continuously (automated, prune+selfHeal).
* **The cluster pulls images** exclusively through the Nexus mirror
  (`registries.yaml`: docker.io/quay.io/ghcr.io → `registry.<domain>`,
  containerd-level basic auth, platform CA) — D-16 extended to the cluster.

## 2. gitops-repository layout (D-26 "render & commit")

```
helm-charts/microservice-standard/     the ONLY place workload templates live
applications/<service>/
  values.yaml                          app-level helm values (team-owned)
  base/kustomization.yaml              wraps the rendered manifests
  base/manifests.yaml                  RENDERED by CI (helm template) — committed
  overlays/<env>/kustomization.yaml    namespace · labels · replicas · DIGEST · patches
clusters/<env>/environment.yaml        AppProject + ApplicationSet (templated:
                                       ${PLATFORM_DOMAIN} substituted at push)
scripts/render-app.sh                  local re-render (same command CI runs)
```

Why render-and-commit instead of ArgoCD-side helm rendering:

* git shows the **exact manifests** that will be applied — an MR diff of a
  chart change is a diff of real Kubernetes objects, reviewable by ops.
* deployments are deterministic: no renderer-version drift between what CI
  validated (pinned helm v3.22.1 on agent-general) and what the cluster applies.
* the **digest pin is a one-line kustomize `images:` diff** — promotion,
  rollback and audit are all the same mechanism.
* `base/manifests.yaml` is CI-managed: `updateGitOps` re-renders it on every
  build; humans re-render with `scripts/render-app.sh` (never hand-edit).

## 3. Delivery flow per environment

| env | how digests arrive | who triggers |
|-----|-------------------|--------------|
| dev | every green `main` build → `updateGitOps` pins + pushes | pipeline (automatic) |
| qa  | promotion of the dev digest | `platform/gitops-promotion` job |
| uat | promotion of the qa digest  | `platform/gitops-promotion` job |
| prod| promotion of the uat digest (overlay file is MR/CODEOWNERS-guarded) | `platform/gitops-promotion` job |

**Same digest, never rebuilt** (master spec §12): the artifact that was
scanned, SBOMed and signed in Phase 7 is bit-identical in every environment.
Kyverno re-verifies the cosign signature at admission in each cluster, so a
promotion cannot smuggle an unsigned image even if the gitops repo is tampered
with.

`promoteDigest` reads the source overlay's pinned digest (rejecting the
all-zeros seed placeholder), pins it into the target overlay, commits
(`chore(gitops): promote <svc> <from>→<to> @ sha256:…`), pushes (rebase-retry
for concurrent promotions) and waits for ArgoCD health via `deployApplication`.

**Rollback (D-12)** = promotion with an explicit older `DIGEST` parameter.
The registry keeps every digest; nothing is rebuilt, so rollback is seconds.

## 4. ArgoCD topology

* **app-of-apps**: `platform-root` (installed once from
  `kubernetes/argocd/root-app.yaml`) syncs `clusters/` — materializing one
  AppProject + one ApplicationSet per environment. Its own project whitelists
  exactly one cluster-scoped kind: `AppProject`.
* **ApplicationSet** (git directory generator on `applications/*/overlays/<env>`)
  → app name `<service>-<env>`, namespace `<service>-<env>`, project `<env>`,
  automated prune+selfHeal, `CreateNamespace=true`.
  **Adding a service = adding a directory.** No ArgoCD object is hand-written
  per app.
* **AppProject** per env: sourceRepos = the gitops repo only, destinations =
  in-cluster `*-<env>` namespaces only, `clusterResourceWhitelist: []`
  (applications can never create cluster-scoped resources).
* **Multi-cluster**: `kubernetes/scripts/10-register-cluster.sh <name> <context>`
  registers spokes (`argocd cluster add`); copy `clusters/<env>/` →
  `clusters/<env>-<name>/` with the spoke's destination server + suffixed
  project names — the root app syncs it, no restart. `kubernetes/clusters.yaml`
  is the human-readable registry.
* **Exposure (lab, D-27)**: NodePort 30443 (K3s traefik/servicelb are disabled
  so the platform Traefik keeps :80/:443); UI/API cert is self-signed by
  design — `ARGOCD_OPTS=--insecure` in `secrets/argocd.env`. Option A: set
  `ARGOCD_SERVER_URL_OVERRIDE` before install.

## 5. Admission control (Kyverno, D-28)

| ClusterPolicy | rule | effect |
|---|---|---|
| `verify-image-signature` | cosign `verifyImages` on `registry.<domain>/*` with the platform public key **injected inline** from `secrets/cosign/cosign.pub` | unsigned/foreign-signed images rejected (Enforce) |
| `require-digest-pinning` | pattern `registry.<domain>/*@sha256:*` on all containers | mutable tags and non-platform registries rejected (Enforce) |

Platform namespaces (kube-system, argocd, kyverno, external-secrets,
platform-tools) are excluded — their images are vendor artifacts pulled
through the mirror. After **key rotation** re-run
`kubernetes/kyverno/cosign-public-key.sh` (the policy carries the key inline;
the script is the runbook).

## 6. Secrets: Vault → ESO → pods (D-29)

```
chart values.secrets[]        →  ExternalSecret (rendered per app)
  store: vault-cluster-store     ClusterSecretStore (ESO)
  auth:  kubernetes-<cluster>    Vault k8s auth mount (TokenReview via
         role eso-reader           SA vault-token-reviewer; per-cluster mount)
  read:  secret/data/apps/<service>/<name>  (policy eso-app-secrets — apps/* ONLY)
  out:   in-cluster Secret <name> → envFrom in the Deployment
```

* The gitops-repository contains **key NAMES only** — no values, ever
  (`vault kv put secret/apps/orders-api/db-creds username=… password=…`).
* The ESO identity is the SA `external-secrets:eso-vault-auth`; the Vault role
  binds exactly that SA/namespace with a 1h TTL. No static Vault token exists
  in the cluster.
* TLS: internal-ca mode embeds the platform CA (`caBundle`) in the store;
  letsencrypt mode uses system trust.

## 7. Onboarding a new service (checklist)

1. Service repo builds green through Phase 7 stages (image signed + SBOMed).
2. In `platform/gitops-repository` (MR):
   * copy `applications/orders-api/` → `applications/<slug>/`
   * `values.yaml`: set `image.repository` to **exactly** the pipeline's image
     path `registry.<domain>/<team>/<slug>` (the slug is the service name
     slugified; the team is the GitLab group under `teams/`), probes, resources,
     `config`, `secrets[]` (Vault key names).
   * keep the four overlays; adjust replicas/patches; digest stays all-zeros.
3. Merge. Next build: `updateGitOps` renders the base, pins the dev digest,
   the ApplicationSet creates `<slug>-dev` automatically — no ArgoCD changes.
4. Vault: `vault kv put secret/apps/<slug>/<name> …` for each `secrets[]` entry.
5. Promote with `platform/gitops-promotion` when qa/uat/prod are due.

## 8. Troubleshooting

| symptom | cause → fix |
|---|---|
| `argocd repo add` fails | GITOPS/ARGOCD_GIT_TOKEN invalid (re-run gitlab 50-), or cluster can't resolve/trust `gitlab.<domain>` (k3s `/etc/hosts` + `argocd cert add-git` — install script does both) |
| ApplicationSet creates no apps | path mismatch (`applications/*/overlays/<env>` must exist), or repo credentials broken → `argocd repo get`; check `kubectl -n argocd logs deploy/argocd-applicationset-controller` |
| App stuck `OutOfSync/Unknown` | repo-server clone error: same TLS/credential chain; `kubectl -n argocd logs deploy/argocd-repo-server` |
| pod rejected: "failed to verify signature" | image not signed (Phase 7 `sign` flag off?) or Kyverno missing platform CA (internal-ca: install script patches `SSL_CERT_FILE`) — `kubectl get clusterpolicy verify-image-signature` for message |
| pod rejected: digest pattern | overlay still at zeros (no build/promotion yet) or manifest carries a foreign registry — pin via CI, never by hand |
| ImagePullBackOff 401 from registry.<domain> | node `/etc/rancher/k3s/registries.yaml` auth missing/stale (re-run `install-k3s.sh` after Nexus password rotation; restarts k3s) |
| ClusterSecretStore not Ready | Vault side unconfigured (`vault/scripts/30-k8s-auth.sh`), vault sealed, or node can't reach `vault.<domain>` (hosts entry + ADMIN_IP_ALLOWLIST covers the node IP) |
| ExternalSecret secretKey missing | Vault path/property mismatch: `vault kv get secret/apps/<slug>/<name>` |
| `deployApplication` timeout | app unhealthy (crashloop) → diagnostics are printed from `argocd app get`; fix forward or roll back with an explicit DIGEST promotion |
| kubectl version skew warning | agents pin kubectl v1.35.10 vs server v1.36 — supported (±1 minor); align deliberately at the next pin refresh (D-15) |

---

## 9. Progressive delivery (Argo Rollouts, Phase 9, D-30)

### 9.1 Argo Rollouts v1.10.1

Installed pinned by `kubernetes/rollouts/install-argo-rollouts.sh` (also wired
into `00-bootstrap-cluster.sh`); lab clusters run 1 replica
(`ARGO_ROLLOUTS_REPLICAS`), real clusters 2. ArgoCD evaluates Rollout health
natively, so `deployApplication`/`sync` semantics are unchanged.

### 9.2 Opt-in Rollout per application (chart 1.1.0)

```yaml
# applications/<svc>/values.yaml
rollout:
  enabled: true          # renders argoproj.io Rollout INSTEAD of Deployment
  strategy: canary       # or blueGreen
  canary:
    steps:               # full Argo Rollouts step grammar (analysis: allowed)
      - setWeight: 50
      - pause: { duration: 10s }
      - setWeight: 100
  blueGreen:
    previewServiceEnabled: true
    autoPromotionEnabled: true      # bounded promotion — see 9.4
    scaleDownDelaySeconds: 60
    extra: {}                       # raw passthrough (prePromotionAnalysis…)
```

Chart mechanics: `templates/_helpers.tpl` holds the FULL pod-template
(checksum/config + Prometheus annotations + hardened container) shared by
Deployment and Rollout; HPA `scaleTargetRef.kind` follows the workload;
blue-green gets `<name>-preview` Service. Kyverno policies pass untouched —
Rollouts copy the digest-pinned, signed image from the template.

### 9.3 Kustomize CRD gotchas (PROVEN against kustomize v5.8.3 — copy this pattern)

Rollout is a CRD; the built-in transformers and patch semantics assume core kinds:

| Need | Wrong (fails silently or loudly) | Right |
|---|---|---|
| replica counts | `replicas:` transformer — built-ins are Deployment/StatefulSet/ReplicaSet/RC only ("resource … does not match a config"), and v5.8.3 has **no `kind:` field** there | `configurations: [replicas-config.yaml]` teaching `spec/replicas` for `Rollout`; **the file must live in/below the overlay root** ("security; file … is not in or below") — `../../base/…` is rejected, so each overlay carries a copy |
| pod-template LIST edits (containers) | strategic patch `spec: template: spec: containers: [name+resources]` — CRDs use **JSON-merge**: the whole containers list is REPLACED (image/probes/securityContext lost) | JSON6902: `target: {kind: Rollout, name}` + `op: replace, path: /spec/template/spec/containers/0/resources` |
| steps / map values | — | plain strategic patches merge maps fine (see orders-api uat/prod) |

`orders-api` ships rollout-enabled with per-env canary tuning:
dev/qa 50%→100% (10s), uat 25/50/100 (30s), prod 10/30/60/100 (3×2m).

### 9.4 Verification, smoke tests, automatic rollback (D-31/D-32)

* `verifyDeployment` treats Rollouts first-class: polls `.status.phase`
  (`Healthy` pass / `Degraded` fail-fast / `Paused`-at-timeout fail unless
  `verify.acceptPaused`) — **keep pauses bounded** or verification can never
  conclude. Deployments still use `kubectl rollout status`.
* Identity is enforced post-deploy: every running pod image must end with
  `@<digest signed by this build>`.
* `runPostDeploy` smokes the LIVE service with newman/k6 from the CI agent via
  `kubectl port-forward` (the verifier kubeconfig's only active verb; no
  in-cluster test pods, no network exposure). Conventions:
  `tests/postman/*.postman_collection.json` (+ optional `.env.json` sibling),
  `tests/k6/*.js`; every test receives `BASE_URL`. Absent tests → loud skip.
* `rollbackDeployment(service, env, reason)` re-pins the previous digest found
  in the overlay's own git history and waits for ArgoCD; automatic on verify/
  smoke failure via `gitops.autoRollback` (build still fails — audit trail:
  `revert(gitops): …` commits).

### 9.5 Phase 9 validation

```bash
./kubernetes/rollouts/install-argo-rollouts.sh          # v1.10.1, idempotent
kubectl get crd rollouts.argoproj.io
helm lint gitops-repository/helm-charts/microservice-standard
helm template gitops-repository/applications/orders-api \
  gitops-repository/helm-charts/microservice-standard --namespace orders-api-dev | grep "kind: Rollout"
for e in dev qa uat prod; do
  kustomize build gitops-repository/applications/orders-api/overlays/$e | \
    yq 'select(.kind=="Rollout") | [.metadata.name, .spec.replicas, [.spec.strategy.canary.steps[].setWeight]]'
done
# dev/qa → [1,[50,100]] · uat → [2,[25,50,100]] · prod → [3,[10,30,60,100]]
kubectl auth can-i create pods/portforward -A \
  --as=system:serviceaccount:platform-tools:deploy-verifier   # yes
kubectl auth can-i create pods/exec -A \
  --as=system:serviceaccount:platform-tools:deploy-verifier   # no
```

- [x] Argo Rollouts v1.10.1 pinned + bootstrap-wired + lab replicas knob
- [x] Chart 1.1.0: canary/blue-green opt-in, shared podTemplate, preview Service, HPA kind-switch
- [x] Kustomize CRD patterns proven by live builds of all 4 orders-api overlays
- [x] verifyDeployment / runPostDeploy / rollbackDeployment steps + KubeAccess helper
- [x] RBAC: read-only + rollouts/ESO + pods/portforward create only (no exec/attach)
- [ ] Live canary promotion on target hardware
