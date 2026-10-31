# Enterprise Containerized DevSecOps Platform

Docker Compose-hosted CI/CD control plane (GitLab · Jenkins · SonarQube · Nexus · Vault ·
full observability stack) with GitOps delivery to Kubernetes via ArgoCD.

Supports Python, Java/Spring Boot, .NET, Node.js (npm/pnpm/yarn), React/Angular/Vue — including
monorepos with selective, dependency-aware, parallel microservice builds.

> **Status: ALL 11 PHASES COMPLETE — the platform is delivered.** Pipeline feature-complete
> and observable (Phases 1–10) AND enterprise-hardened (Phase 11: Vault dynamic secrets +
> AppRole, audit → Loki, consistent backups + full-DR toolkit, LDAP/OIDC realm cutover kits,
> TLS AEAD-only posture, performance runbooks). Every phase was delivered with live
> validation — never placeholders. Remaining work is site-specific: run the installation
> runbooks on target hardware and schedule the quarterly restore drill (backup-recovery.md §8).

## Phase roadmap & delivery tracker

| Phase | Scope | Key artifacts | Status |
|-------|-------|---------------|--------|
| **1** | Architecture, networks, storage, sizing, security boundaries, version matrix | `documentation/architecture.md` | ✅ **Complete** |
| **2** | Docker Compose infrastructure | `docker-compose.yml` + override/prod, `.env.example`, 8 networks, healthchecks, Traefik TLS routing, Prometheus/Loki/Alloy/Alertmanager configs, Vault raft, `scripts/bootstrap.sh` `validate.sh` `health-check.sh` `cleanup.sh` | ✅ **Complete** |
| **3** | Jenkins custom controller | `jenkins/Dockerfile` (2.568.3 LTS + 29 pinned plugins), 6-file JCasC (role matrix, credentials, Docker cloud, warm nodes, integrations), 7 agent images, shared-library foundation (`microservicePipeline`, `detectProject`, policy engine) | ✅ **Complete** |
| **4** | GitLab setup | `gitlab/scripts/` API automation: root PAT bootstrap, groups/users/service PATs (ci-api, gitops-write), projects + protected branches/tags, memberships, repo seeding (shared library + GitOps skeleton + CODEOWNERS), webhook tooling, CE-limitation handling, security.md credential/RBAC guide | ✅ **Complete** |
| **5** | SonarQube + Nexus | `sonarqube/scripts/` + `nexus/scripts/` API automation (admin rotation, anonymous lockdown, CI tokens, quality gates default+strict, 17 repositories, 6 cleanup policies, jenkins-deploy role), `vars/runSonarAnalysis.groovy` (scanner-side gate wait D-20, CE branch isolation), quality stage flag ON | ✅ **Complete** |
| **6** | Multi-language CI | language/package-manager auto-detection (Python · Maven · Gradle · .NET · npm/pnpm/yarn · React/Angular/Vue), per-language build+test pipelines on dedicated agents, monorepo selective builds (change-scoped service detection + parallel fan-out), artifact publishing to Nexus | ✅ **Complete** |
| **7** | DevSecOps tooling | 6 gate steps (gitleaks pre-build+confirm, semgrep offline rules, trivy fs+image-by-digest, OWASP DC via host-updated NVD mirror, syft SBOM→raw-hosted, cosign sign-by-digest) + `FindingGate`/`RegistryAuth` policy enforcement, exception register wiring, ghcr-proxy, cosign keypair provisioning scripts; all 7 flags ON | ✅ **Complete** |
| **8** | GitOps | K3s v1.36.5 (Option B, traefik/servicelb off + Nexus mirrors) / `10-register-cluster.sh` (Option A), ArgoCD v3.4.8 (NodePort, `jenkins-cd` get/sync-only RBAC, app-of-apps → AppProjects + ApplicationSets per env), `microservice-standard` chart + render-and-commit overlays (digest pinning), `updateGitOps`/`deployApplication`/`promoteDigest` + `platform/gitops-promotion` job, Kyverno verify-signature + digest-pinning (Enforce), ESO→Vault KV v2 (per-cluster k8s auth) | ✅ **Complete** |
| **9** | Advanced release | Argo Rollouts v1.10.1 canary/blue-green as chart-1.1.0 opt-in `Rollout` (shared `podTemplate` helper, preview Service, HPA kind-switch; Kustomize CRD patterns proven: per-overlay `replicas-config.yaml` + JSON6902 pod-spec patches), `verifyDeployment` (read-only kubeconfig: convergence incl. Rollout `phase`, readyReplicas, pod-image==signed-digest identity, pathology scan, ExternalSecret readiness), `runPostDeploy` (newman/k6 discovered from `tests/` conventions, BASE_URL via explicit config or `kubectl port-forward`, loud skip when absent), `rollbackDeployment` (previous digest from overlay's own git history, auto on failure via `gitops.autoRollback`, build still fails), agent-general += k6 v2.3.0 / node v22.23.4 / newman 6.2.3, verifier RBAC += `pods/portforward` create + argoproj.io/ESO read — all 20 stage flags ON | ✅ **Complete** |
| **10** | Observability | Scrape targets completed (jenkins→monitoring-network, gitlab-exporter :9168, nexus metrics capability + zero-priv account with `password_file`), alert suites (cicd.yml, SLO burn-rates slo.yml, Watchdog heartbeat, Loki embedded-ruler log-alerts), Alertmanager live receivers (Slack/MSTeams/SMTP via `*_file` secrets + parse-safe bootstrap placeholders), 5 provisioned Grafana dashboards (overview+SLOs, CI/CD, infra, security+vault, logs), Alloy healthcheck-noise drop, SLOs 99.5%/99.9% multi-window burn-rate, `notifyResult` deployment_failed/rollback_executed hooks, `monitoring/scripts/` (nexus-metrics + configure-notifications) | ✅ **Complete** |
| **11** | Enterprise hardening | Vault `jenkins-platform` policy + AppRole (1h tokens, `withVault` wired via JCasC `vaultConfiguration`), platform-secret seeding, audit device → Alloy tail → Loki `vault-audit`, native consistent dumps ×4 (vault raft/gitlab/pg_dumpall/nexus task) + `backup-now.sh` + `restore.sh` (files/vault-raft/gitlab/sonar-db/all) + full-DR runbook, LDAP/OIDC realm cutover kits (pinned oic-auth, break-glass), TLS AEAD-only cipher suites + rotation runbooks, performance.md (sizing/capacity/bottlenecks/load procedure) | ✅ **Complete** |

## Repository layout

See `documentation/architecture.md` §19-aligned tree. Highlights:

- `documentation/` — architecture (done), installation, security, pipeline, troubleshooting, backup-recovery (grow per phase)
- `jenkins/` — custom controller image, JCasC, shared library (`vars/` + `src/org/company/devsecops/`), agent Dockerfiles
- `gitops/` — the GitOps repository content (clusters, applications, `helm-charts/microservice-standard`)
- `security/` — scanner configs + centralized policy engine + exception register
- `monitoring/` — Prometheus, Grafana provisioning/dashboards, Loki, Alloy, Alertmanager
- `scripts/` — bootstrap / validate / health-check / backup / restore / cleanup

## Quick start (Phase 2 — working today)

```bash
cp .env.example .env                     # edit PLATFORM_DOMAIN, DATA_ROOT, sizing
./scripts/bootstrap.sh --all             # sysctls, secrets, internal-CA TLS, compose up
./scripts/health-check.sh --wait         # live endpoint matrix through Traefik
```

Full procedure, expected outputs, one-time initializations (Vault init/unseal, GitLab,
Jenkins wizard, Nexus admin password) and troubleshooting: `documentation/installation.md`.

## Non-negotiables (enforced across all phases)

- Pinned image versions only — no `latest`.
- No unrestricted Docker socket on the Jenkins controller; rootless BuildKit for image builds.
- No secrets in Git or plain-text Jenkinsfiles; Vault is the source of truth.
- Images deployed **by immutable digest**, signed with Cosign, verified by Kyverno.
- Jenkins never `kubectl apply`s to production; ArgoCD owns reconciliation.
- Security gates can be tightened by projects, never silently relaxed; exceptions have owner,
  justification, approval and expiry.
