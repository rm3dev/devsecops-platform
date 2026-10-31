# GitOps Repository

Single source of truth for everything deployed to the Kubernetes clusters,
reconciled by ArgoCD (app-of-apps: `platform-root` → `clusters/*/environment.yaml`
→ one Application per service per environment).

```
helm-charts/microservice-standard/   shared chart — the ONLY place templates change
applications/<service>/
  values.yaml                        application-level helm values (image repo, probes, resources, config, ESO secrets)
  base/
    kustomization.yaml               wraps the rendered manifests
    manifests.yaml                   RENDERED OUTPUT (helm template chart + values.yaml) — CI-managed, never hand-edited
  overlays/{dev,qa,uat,prod}/
    kustomization.yaml               namespace, labels, replicas, IMAGE DIGEST pin, env patches
clusters/{dev,qa,uat,prod}/
  environment.yaml                   AppProject + ApplicationSet (templated: ${PLATFORM_DOMAIN} substituted at push)
scripts/render-app.sh                local re-render helper (same command CI uses)
```

## Rules

* Images are referenced **by immutable digest only** — `updateGitOps` (CI)
  rewrites `images[].digest` in the target environment overlay after every
  green build; `promoteDigest` (platform/gitops-promotion job) copies the
  SAME digest environment→environment. Tag-only references are rejected by
  the Kyverno `require-digest-pinning` policy.
* `main` is protected: the `jenkins-ci` bot and platform admins push;
  force-push denied. Prod overlay changes should flow through MR review
  (CODEOWNERS enforcement activates with a Premium license — D-19).
* **No plaintext secrets anywhere.** Application secrets are External Secrets
  Operator references to Vault (`secret/data/apps/<service>/<name>`); the
  values files only carry key NAMES.
* Chart changes affect every service: bump `helm-charts/microservice-standard/
  Chart.yaml:version`, then let CI re-render each app on its next build (or
  run `scripts/render-app.sh <svc>` for all apps in an MR).
* Onboarding a new service: copy `applications/orders-api/` → adjust
  `values.yaml` (image.repository MUST match the pipeline's
  `registry.<domain>/<team>/<service>`) → create the four overlays (digest
  placeholder zeros) → next build's `updateGitOps` pins the real digest and
  the ApplicationSet creates the ArgoCD Application automatically.

## Sync model

| env | ArgoCD sync | how digests arrive |
|-----|-------------|--------------------|
| dev | automated (prune, selfHeal) | every green `main` build (`updateGitOps`) |
| qa  | automated | promotion from dev (`platform/gitops-promotion`) |
| uat | automated | promotion from qa |
| prod| automated | promotion from uat — MR-reviewed overlay file |

Rollback = re-pin a previous digest (D-12): `promoteDigest` with an explicit
`DIGEST` parameter, or revert the overlay commit. The registry keeps every
digest; nothing is ever rebuilt for a rollback.
