# PHASE 1 — Platform Architecture & Resource Plan

> Enterprise Containerized DevSecOps Platform
> Document version: 1.0 · Date: 2026-10-30 · Status: **Approved baseline for implementation**
> All component versions in this document were verified against official release sources on 2026-10-30.

---

## 1. Objective

Define the complete architecture for an enterprise-grade DevSecOps platform in which:

- The **CI/CD control plane** (SCM, CI orchestration, quality, artifacts, secrets, observability) runs
  100% in Docker containers orchestrated by **Docker Compose** on one (or an HA pair of) Linux host(s).
- The **application deployment plane** runs on **Kubernetes**, with **ArgoCD installed inside the
  cluster** performing GitOps reconciliation.
- Jenkins never deploys to production with `kubectl apply`; it publishes immutable, signed images
  to Nexus, updates the GitOps repository, and observes ArgoCD/Kubernetes health through APIs.

Phase 1 fixes: component topology, container inventory, network design, port/hostname mapping,
storage & volume design, resource sizing, security boundaries, the pinned version matrix, and the
decision log that Phases 2–11 will implement without deviation.

---

## 2. High-Level Architecture

```
                                 ┌──────────────────────────────────────────────────────────────┐
                                 │             DOCKER HOST(S) — CI/CD CONTROL PLANE             │
                                 │                                                              │
  Developers ──HTTPS──►          │  ┌─────────┐   frontend-network                              │
  (git, web UIs)         443     │  │ Traefik │─────────────────────────────────────┐           │
  Git over SSH ─────────►2222    │  │  v3.7   │  TLS termination, routing, headers  │           │
                                 │  └─────────┘                                     ▼           │
                                 │   ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────┐     │
                                 │   │ GitLab   │ │ Jenkins  │ │SonarQube │ │    Nexus     │     │
                                 │   │ CE 19.5  │ │ 2.568.3  │ │26.10 CE  │ │   3.96.4     │     │
                                 │   └──────────┘ └──────────┘ └──────────┘ └──────────────┘     │
                                 │    scm-network   cicd-network  cicd-network  artifact-network │
                                 │        │             │  ▲                        ▲           │
                                 │        │             │  │ credentials            │ push/pull │
                                 │        │             ▼  │                        │           │
                                 │        │      ┌───────────────────┐   ┌──────────┴─────────┐ │
                                 │        │      │  Build agents     │   │  BuildKit (rootless)│ │
                                 │        │      │  (dynamic + pool) │──►│  image builds       │ │
                                 │        │      │  py/java/dotnet/  │   └─────────────────────┘ │
                                 │        │      │  node/security    │                           │
                                 │        │      └───────────────────┘                           │
                                 │        │       security-network: Trivy · Gitleaks · Semgrep   │
                                 │        │       Syft · Cosign · Dependency-Check (on-demand)   │
                                 │        │                                                     │
                                 │   ┌────┴─────┐   management-network                          │
                                 │   │  Vault   │◄── Jenkins (AppRole) — dynamic secrets        │
                                 │   │  2.2.1   │                                               │
                                 │   └──────────┘                                               │
                                 │                                                              │
                                 │   monitoring-network: Prometheus · Grafana · Loki · Alloy    │
                                 │                       Alertmanager · node-exporter · cAdvisor│
                                 └──────────────────────────────────────────────────────────────┘
                                                      │
                    Jenkins ──(1) push signed image──►│ Nexus docker-group/hosted
                    Jenkins ──(2) commit digest──────►│ GitLab `gitops-repository`
                                                      ▼
                                 ┌──────────────────────────────────────────────┐
                                 │        KUBERNESCLUSTER(S) — DEPLOYMENT PLANE │
                                 │  Option A: existing managed/self-hosted k8s  │
                                 │  Option B: K3s v1.35.x lab cluster (compose  │
                                 │            host may also run k3s container)  │
                                 │                                              │
                                 │  ArgoCD v3.4.8 (in-cluster)                  │
                                 │  Argo Rollouts (canary/blue-green)           │
                                 │  External Secrets Operator ◄── Vault         │
                                 │  Kyverno (policy + cosign verify)            │
                                 │  Namespaces: dev / qa / uat / prod           │
                                 └──────────────────────────────────────────────┘
```

### 2.1 Control-plane / deployment-plane split (the ArgoCD boundary)

ArgoCD is a Kubernetes-native controller set. It is **never** run as a plain Docker Compose service
pretending to be a deployment controller. Two supported options:

| | **Option A — Existing Kubernetes cluster** | **Option B — Dedicated K3s lab cluster** |
|---|---|---|
| Where ArgoCD runs | In the customer/lab Kubernetes cluster | In a K3s cluster created by this project |
| Cluster provisioning | Out of scope (cluster pre-exists) | `scripts/k3s/` installs K3s v1.35.x on a second host or VM (or as a `k3s` container for single-host labs) |
| Registration | Jenkins registers clusters via `argocd cluster add` (Phase 8) | Same, `in-cluster` + K3s |
| Recommended for | Production | Lab / PoC / acceptance tests (Tests 12–16 of §22) |

**Decision D-01:** the reference implementation ships **Option B (K3s)** so the whole platform is
reproducible on lab hardware, while every ArgoCD artifact (AppProjects, Applications,
ApplicationSets, RBAC) is written to work unchanged with Option A. Multi-cluster support is
implemented via ArgoCD cluster secrets — dev/qa on one cluster, uat/prod on another is a
configuration change, not an architecture change.

### 2.2 End-to-end delivery flow

1. Developer pushes to GitLab → webhook → Jenkins multibranch pipeline (or GitLab Branch Source poll).
2. Pipeline (shared library `microservicePipeline`) runs Stages 1–15: discovery → secrets scan →
   build → tests → Sonar quality gate → SAST → SCA → package → BuildKit image → Trivy image scan →
   Syft SBOM → Cosign sign → push to Nexus by **digest**.
3. Stage 16: pipeline updates `gitops-repository` (Helm values / Kustomize image digest) via a
   short-lived Vault-issued GitLab token, commits with `[skip ci]`, tags release metadata.
4. Stage 17–18: ArgoCD auto-syncs **dev**; qa/uat sync on approval-triggered operation; prod syncs
   only after authorized Jenkins approval + ArgoCD sync window. Jenkins polls ArgoCD
   `application/get` + Kubernetes rollout/readiness (read-only kubeconfig) — never applies manifests.
5. Stage 19–20: smoke/API tests (Newman), performance (k6), then final reporting + notifications.
6. Rollback: on failed verification the pipeline re-pins the **previous known-good digest** in the
   GitOps repo (GitOps-consistent rollback) or triggers `argocd app rollback` for history-based
   recovery — decided by actual ArgoCD/K8s health, never by a bare Jenkins timeout.

---

## 3. Container Inventory & Pinned Version Matrix

All versions verified 2026-10-30 against official sources. **No `latest` tags anywhere.**
Re-run `scripts/validate.sh --versions` at bootstrap; pin policy = explicit patch versions.

### 3.1 Core control plane (Compose profile: `core`)

| # | Service | Image (pinned) | Verified release date | Role |
|---|---------|----------------|-----------------------|------|
| 1 | `gitlab` | `gitlab/gitlab-ce:19.5.1-ce.0` | 2026-10-21 patch line | SCM, webhooks, MRs, GitOps repo hosting |
| 2 | `jenkins` | `jenkins/jenkins:2.568.3-lts-jdk21` (custom Dockerfile `FROM` this) | 2.568.3 LTS, Oct 2026 | CI orchestrator (controller does no builds) |
| 3 | `sonarqube-db` | `postgres:17.4-alpine` | PostgreSQL 17 = supported by SonarQube 26.x | SonarQube database |
| 4 | `sonarqube` | `sonarqube:26.10.0.133078-community` | 2026-10-23 | Code quality, gates, coverage |
| 5 | `nexus` | `sonatype/nexus3:3.96.4` | 2026-09-30 | Artifacts + Docker registry (hosted/proxy/group) |
| 6 | `vault` | `hashicorp/vault:2.2.1` | 2026-10-22 | Secrets, dynamic creds, AppRole for Jenkins |
| 7 | `traefik` | `traefik:v3.7.13` | 2026-09-04 | TLS reverse proxy, single ingress point |

### 3.2 Monitoring (Compose profile: `monitoring`)

| # | Service | Image (pinned) | Notes |
|---|---------|----------------|-------|
| 8 | `prometheus` | `prom/prometheus:v3.13.5` | 2026-10-21 security release; Prometheus 3.x |
| 9 | `alertmanager` | `prom/alertmanager:v0.28.1` | Pairs with Prometheus 3.x |
| 10 | `grafana` | `grafana/grafana-oss:13.3.0` | 2026-10-27 |
| 11 | `loki` | `grafana/loki:3.7.9` | 2026-10-20; monolithic mode, filesystem storage |
| 12 | `alloy` | `grafana/alloy:v1.21.2` | 2026-10-22; Alloy is the supported successor to Promtail (D-10) |
| 13 | `node-exporter` | `prom/node-exporter:v1.9.1` | Host metrics |
| 14 | `cadvisor` | `gcr.io/cadvisor/cadvisor:v0.49.1` | Container metrics |

### 3.3 Build & tooling plane (Compose profiles: `build` / on-demand)

| # | Service/Tool | Image (pinned) | Lifecycle | Notes |
|---|--------------|----------------|-----------|-------|
| 15 | `buildkitd` | `moby/buildkit:v0.34.1-rootless` | Long-running, isolated | **Rootless** image builds; no host Docker socket in Jenkins controller (Decision D-04) |
| 16 | `docker-socket-proxy` | `ghcr.io/tecnativa/docker-socket-proxy:v0.5.0` | Long-running | Allow-listed Docker API for dynamic agent provisioning only |
| 17–23 | Jenkins agents: `agent-python`, `agent-java-maven`, `agent-java-gradle`, `agent-dotnet`, `agent-nodejs`, `agent-security`, `agent-general` | Custom Dockerfiles (Phase 3) | **Warm pool of 3 + dynamic via Docker Cloud plugin** | JNLP inbound agents, labels `py|java-maven|java-gradle|dotnet|node|security|general` |
| 24 | Trivy | `aquasec/trivy:0.76.1` (2026-10-21) | On-demand `docker run` | fs / image / config / SBOM scanning; DB cached on `trivy-cache` volume |
| 25 | Gitleaks | `zricethezav/gitleaks:v8.28.x` (patch pinned Phase 7) | On-demand | Git-history + worktree secret scan |
| 26 | Semgrep | `semgrep/semgrep:v1.14x` (patch pinned Phase 7) | On-demand | SAST rulesets + custom rules from `security/semgrep/rules` |
| 27 | Syft | `anchore/syft:v1.x` (patch pinned Phase 7) | On-demand | CycloneDX + SPDX SBOM |
| 28 | Cosign | `ghcr.io/sigstore/cosign/cosign:v3.x` (patch pinned Phase 7) | On-demand | Key-based signing (keys in Vault); keyless optional |
| 29 | OWASP Dependency-Check | `owasp/dependency-check:12.x` (patch pinned Phase 7) | Scheduled/weekly container | NVD mirror on volume; Java/Maven ecosystem supplement |
| 30 | k6 | `grafana/k6:1.x` (patch pinned Phase 9) | On-demand | Performance/smoke tests |
| 31 | Newman | `postman/newman_alpine33:6.x` (patch pinned Phase 9) | On-demand | Postman API tests |
| 32 | Backup runner | `restic/restic:0.18.1` | Long-running loop (profile `backup`) | File-level restic backups now; consistent component dumps added Phase 11 (§ 12) |

### 3.4 Kubernetes plane (not in Compose, except optional K3s)

| Component | Version | Notes |
|-----------|---------|-------|
| K3s (Option B) | `v1.35.x+k3s1` (1.35 is the maintained mid-2026 line; v1.36 was still pre-GA for k3s) | Single-node lab cluster; second node optional |
| ArgoCD | `v3.4.8` (quay.io/argoproj/argocd) | Supported lines 3.3/3.4/3.5 — 3.4 chosen for maturity; install requires `kubectl apply --server-side` |
| Argo Rollouts | `v1.8.x` (patch pinned Phase 9) | Canary / blue-green |
| Helm | `v3.18.x` on agents; `helm-controller` conventions for GitOps chart | Standard `microservice-standard` chart |
| Kustomize | Bundled with `kubectl` / ArgoCD | Overlays per environment |
| Kyverno | `v1.14.x` (Phase 8) | Policy enforcement + `verifyImages` (cosign) admission rule |
| External Secrets Operator | `v0.19.x` (Phase 8) | Vault → K8s secrets; no plaintext prod values |
| Kubescape | `v3.x` CLI on security agent (Phase 8) | Cluster posture scans, scheduled |

---

## 4. Network Design

### 4.1 Docker networks (all `internal: true` except `frontend-network`)

| Network | Subnet (default pool) | Purpose | Members |
|---------|----------------------|---------|---------|
| `frontend-network` | 172.30.0.0/24 | Only network with host-published ports (via Traefik) | traefik, gitlab, jenkins, sonarqube, nexus, grafana, vault (admin-filtered) |
| `scm-network` | 172.30.1.0/24 | Git/API traffic to GitLab | gitlab, jenkins, agents, backup |
| `cicd-network` | 172.30.2.0/24 | Controller↔agents, build orchestration | jenkins, socket-proxy, buildkitd, all agents |
| `artifact-network` | 172.30.3.0/24 | Artifact & image pull/push | nexus, jenkins, agents, buildkitd, sonarqube (plugin downloads), trivy (base-image cache) |
| `security-network` | 172.30.4.0/24 | Scanner traffic isolation | vault, jenkins, agents, on-demand scanner containers |
| `monitoring-network` | 172.30.5.0/24 | Metrics/log scraping only | prometheus, alertmanager, grafana, loki, alloy, node-exporter, cadvisor + scrape targets (gitlab, jenkins, nexus, sonarqube, traefik) |
| `management-network` | 172.30.6.0/24 | Backup, admin CLI, DB access | postgres, sonarqube, backup, vault, jenkins (maintenance) |
| `agents-network` (D-16, Phase 3) | 172.30.7.0/24, `internal: true` | Dedicated build-agent plane: agents reach ONLY jenkins, gitlab, sonarqube, nexus, vault, buildkitd — **no direct internet egress**; dependencies flow exclusively via Nexus. Also solves docker-plugin's single-network-per-template constraint | jenkins, gitlab, sonarqube, nexus, vault, buildkitd, warm agents, dynamic agent containers |

Rules enforced by design and by `scripts/validate.sh`:

- **No service except `traefik` publishes host ports** (exception: GitLab SSH `2222→22` for git-over-SSH,
  documented in §5; and node-exporter/cAdvisor bind nothing on the host beyond internal metrics).
- `postgres`, `vault`, `nexus` admin APIs, Prometheus, Alertmanager, Loki are **never** reachable from
  `frontend-network` without Traefik middleware (auth/IPAllowList) — DB and Vault are not on
  `frontend-network` at all.
- On-demand security containers join **only** `security-network` (+ `artifact-network` when pulling images).

### 4.2 Container-to-container communication matrix (source → destination : port / protocol)

| Source | Destination | Port | Purpose |
|--------|-------------|------|---------|
| traefik | gitlab | 80/http, 22 (ssh passthrough) | Web UI, git HTTP, SSH |
| traefik | jenkins | 8080 | UI + API (webhook receiver) |
| traefik | sonarqube | 9000 | UI + scanner API |
| traefik | nexus | 8081 | UI + REST |
| traefik | nexus | 8085 | docker-group registry (SNI TLS router → `registry.<domain>`) |
| traefik | grafana | 3000 | Dashboards |
| traefik | vault | 8200 | Admin UI/API — behind IPAllowList + mTLS client-auth middleware |
| gitlab → jenkins | webhook over `scm-network` | 8080 | MR/push events (via Jenkins GitLab plugin endpoint) |
| jenkins → gitlab | `gitlab:80/git` | clone, commit-status, MR notes, GitOps repo writes |
| jenkins → sonarqube | `sonarqube:9000/api` | quality-gate webhook + token auth |
| jenkins → nexus | `nexus:8081/service/rest` | publish, promotion, cleanup |
| jenkins → vault | `vault:8200/v1` | AppRole login, dynamic creds, transit (cosign keys) |
| jenkins → socket-proxy | `docker-socket-proxy:2375` | Docker Cloud plugin: create/start/stop agent containers only (allow-list) |
| agents → jenkins | `jenkins:50000` | JNLP inbound agent channel |
| agents → buildkitd | `buildkitd:1234` | rootless BuildKit over TCP (TLS optional; isolated network) |
| agents/buildkitd → nexus | `nexus:8085` (group), `8083` (hosted push) | base image pulls; image push by digest |
| agents → nexus | 8081 + language-group endpoints | maven/npm/pypi/nuget/raw |
| trivy/syft/cosign (on-demand) | nexus:8085, agents workspace bind | scan & sign published digests |
| prometheus → all targets | jenkins:8080/prometheus, gitlab:80/-/metrics (whitelist), nexus:8081/service/metrics/prometheus, sonarqube:9000/api/monitoring/metrics (CE partial), node-exporter:9100, cadvisor:8080, traefik:8082, buildkitd:1234 metrics | scraping on `monitoring-network` |
| alloy → docker socket (read-only, via socket-proxy) + /var/log (ro bind) | container log discovery → loki:3100 |
| grafana → prometheus:9090, loki:3100 | queries |
| prometheus → alertmanager:9093 | alerts |
| jenkins → argocd (K8s ingress) | `https://argocd.<k8s-domain>/api/v1` | sync trigger (qa/uat/prod), health/status polling |
| jenkins → kube-apiserver | 6443, **read-only** ServiceAccount | rollout/readiness verification only |
| argocd → gitlab | 443/22 | poll GitOps repo (deploy key / project token) |
| ESO (in K8s) → vault | 8200 (via ingress or direct route) | Kubernetes auth → secret sync |

### 4.3 Hostname & routing plan (Traefik, `reverse-proxy/configuration/`)

Base domain: `${PLATFORM_DOMAIN}` (default `devsecops.internal`; real DNS or `/etc/hosts` in lab).

| Hostname | Backend | Middleware |
|----------|---------|------------|
| `gitlab.${PLATFORM_DOMAIN}` | gitlab:80 | secure-headers, HSTS |
| `jenkins.${PLATFORM_DOMAIN}` | jenkins:8080 | secure-headers (Jenkins sets `X-Url` behind proxy) |
| `sonar.${PLATFORM_DOMAIN}` | sonarqube:9000 | secure-headers |
| `nexus.${PLATFORM_DOMAIN}` | nexus:8081 | secure-headers |
| `registry.${PLATFORM_DOMAIN}` | nexus:8085 (docker-group) | TLS SNI router; docker clients use this as registry host |
| `vault.${PLATFORM_DOMAIN}` | vault:8200 | `ipallowlist-admin`, rate-limit |
| `grafana.${PLATFORM_DOMAIN}` | grafana:3000 | secure-headers |
| `prometheus.${PLATFORM_DOMAIN}` (optional, prod: disabled) | prometheus:9090 | `basicauth-monitoring` |
| `alertmanager.${PLATFORM_DOMAIN}` (optional) | alertmanager:9093 | `basicauth-monitoring` |
| `argocd.${K8S_DOMAIN}` | (Kubernetes ingress, not Traefik) | ArgoCD-managed |

TLS strategy: internal CA (`reverse-proxy/certificates/`, generated by `scripts/bootstrap.sh` via
`step-ca`/`openssl` in lab; Let's Encrypt ACME or corporate CA in production). GitLab, Jenkins,
SonarQube, Nexus, Grafana all terminate TLS **only at Traefik** — backends speak plain HTTP on
internal networks. Registry traffic (`docker login registry.<domain>`) works because Traefik serves
the corporate CA cert chain; Docker hosts trust the CA via `/etc/docker/certs.d/`.

---

## 5. Port Mapping (the complete host-exposure list)

| Host port | Service | Justification |
|-----------|---------|---------------|
| `443/tcp` | traefik | Single HTTPS ingress for all UIs/APIs/registry |
| `80/tcp` | traefik | HTTP→HTTPS redirect + ACME challenge only |
| `2222/tcp` | gitlab (container 22) | Git over SSH (cannot HTTP-proxy SSH; alternative: disable and use HTTPS git only) |
| `50000/tcp` | **not published** | JNLP agent port stays internal (agents are containers on `cicd-network`) |
| everything else | **none** | postgres 5432, vault 8200, nexus 8081/8083/8085, sonar 9000, jenkins 8080, prometheus 9090, loki 3100, grafana 3000, buildkitd 1234 — reachable **only** on internal Docker networks via Traefik or peer containers |

Kubernetes plane (Option B K3s): `6443` (API, firewalled to Jenkins host + admin subnet),
`443` (cluster ingress for ArgoCD + apps) on the K3s host only.

---

## 6. Storage & Volume Design

### 6.1 Host layout

```
/opt/devsecops/                     # project checkout (compose files, configs)
/mnt/data/devsecops/                # bind-mounted data root (dedicated disk/LS recommended)
 ├── gitlab/{config,logs,data}      # GitLab omnibus directories (bind mounts, gitlab wants paths)
 ├── nexus-data/                    # nexus blob store + db (bind; nexus uid 200)
 ├── vault/{data,file,config}       # raft/file storage + config (uid 100)
 ├── sonarqube/{data,extensions,logs}
 ├── jenkins-home/                  # JENKINS_HOME (bind, so backup & JCasC survive image rebuilds)
 ├── prometheus-data/  grafana-data/  loki-data/
 ├── buildkit-cache/                # buildkitd state + cache
 ├── agent-workspaces/              # per-agent workspace root (jenkins uid 1000)
 └── backups/staging/               # restic staging before off-host push
```

Rationale for bind mounts over named volumes: GitLab, Nexus and Vault are uid-sensitive and their
backup tooling expects POSIX paths; bind mounts under `/mnt/data/devsecops` keep everything on one
mountable, snapshot-able filesystem. Named volumes are used only for throwaway state
(`trivy-cache`, `m2-cache`, `npm-cache`, `gradle-cache`, `nuget-cache`, `pip-cache`, `nvd-data`).

### 6.2 Capacity plan

| Dataset | Lab sizing | Production sizing | Growth driver | Retention control |
|---------|-----------|-------------------|---------------|-------------------|
| GitLab repos+db | 100 GB | 500 GB–1 TB | source + GitOps history | GitLab housekeeping, backup retention 14 d |
| Nexus blobs | 200 GB | 1–4 TB | images dominate | cleanup policies (Phase 5): keep last N tags per service, snapshots 7 d, `latest` banned |
| SonarQube data | 50 GB | 100–200 GB | analysis history | housekeeping: keep 30 days of CPD/measure history |
| Jenkins home | 30 GB | 100 GB | builds, workspaces | per-job build discarding (30 builds/90 days), workspace cleanup post-build |
| Prometheus TSDB | 30 GB | 60–100 GB | 15 d retention, ~50 k series | `--storage.tsdb.retention.time=15d` |
| Loki chunks | 30 GB | 100 GB | 14 d retention | compactor retention enforced |
| Vault | 5 GB | 10 GB | raft + audit logs | audit device → Loki, snapshot rotation |
| Backups (staging) | 100 GB | ≥ 1.5× live dataset | daily fulls of small DBs + incrementals | restic forget: 7 daily / 4 weekly / 6 monthly |

**Total: lab host ≥ 500 GB data disk; production control-plane host ≥ 2 TB (SSD).**
Nexus and GitLab data directories should sit on separate devices/LVs in production (I/O isolation).

### 6.3 Volume → container ownership matrix (uid/gid)

| Path | Container | uid:gid | Notes |
|------|-----------|---------|-------|
| gitlab/* | gitlab | root-in-container (omnibus requirement) | Container itself is rootful by design; all other core services non-root |
| jenkins-home, agent-workspaces | jenkins, agents | 1000:1000 | `JENKINS_UID` configurable |
| nexus-data | nexus | 200:200 | official image requirement |
| sonarqube/* | sonarqube | 1000:1000 | ES inside SonarQube also needs `vm.max_map_count≥524288` and write access to `/tmp` (26.x requirement) |
| vault/{data,file} | vault | 100:1000 | non-root-capable |
| prometheus-data | prometheus | 65534:65534 | nobody |
| loki-data | loki | 10001:10001 | |
| grafana-data | grafana | 472:472 | |

---

## 7. Resource Sizing (CPU/memory limits & reservations)

Two sizing profiles. Compose `deploy.resources.limits` are set in `docker-compose.yml` (hard caps),
requests-equivalent via `mem_reservation`. Values below are **limits**; reservation = 50% of limit.

### 7.1 Per-service limits

| Service | Lab (vCPU / RAM) | Production (vCPU / RAM) | Notes |
|---------|------------------|-------------------------|-------|
| traefik | 0.5 / 256 MB | 1 / 512 MB | |
| gitlab | 4 / 8 GB | 8 / 16 GB | puma 2 workers, sidekiq 10 (lab); tuned in `gitlab/config/gitlab.rb` |
| jenkins controller | 2 / 4 GB | 4 / 8 GB | `-Xmx2g` (lab) / `-Xmx4g`; **executors = 0** |
| sonarqube-db | 1 / 2 GB | 2 / 4 GB | shared_buffers tuned Phase 5 |
| sonarqube | 2 / 6 GB | 4 / 10 GB | CE task + ES inside; `SONAR_WEB_JVMXMX` etc. set in env |
| nexus | 2 / 6 GB | 4 / 12 GB | `-Xmx4g` default; blob store I/O bound |
| vault | 0.5 / 512 MB | 1 / 1 GB | |
| buildkitd | 4 / 8 GB | 8 / 16 GB | main build muscle; cache export capped |
| docker-socket-proxy | 0.2 / 64 MB | 0.2 / 64 MB | |
| prometheus | 1 / 2 GB | 2 / 6 GB | |
| grafana | 0.5 / 512 MB | 1 / 1 GB | |
| loki | 0.5 / 1 GB | 1 / 2 GB | |
| alloy | 0.5 / 512 MB | 1 / 1 GB | |
| alertmanager | 0.2 / 128 MB | 0.2 / 256 MB | |
| node-exporter | 0.2 / 128 MB | 0.2 / 128 MB | |
| cadvisor | 0.5 / 512 MB | 0.5 / 1 GB | `--docker_only`, housekeeping 15 s |
| agent (each) | 2 / 4 GB | 4 / 8 GB | java-maven agent +2 GB headroom |
| on-demand scanners | 2 / 2 GB (trivy), 1 / 1 GB (others) | same | ephemeral |

### 7.2 Host sizing

| Profile | vCPU | RAM | Disk | Supports |
|---------|------|-----|------|----------|
| **Lab / PoC** (single host incl. K3s-in-Docker) | 16 | 48 GB | 500 GB SSD | ~10 devs, 20 services, 10 concurrent pipelines |
| **Production control plane** (K3s/k8s on separate nodes) | 32 | 96–128 GB | 2 TB NVMe + 2 TB backup | 50–100 devs, 100+ services, 30–40 concurrent pipelines |
| Scale-out trigger | — | — | — | >60 concurrent builds → second Jenkins controller or agent hosts (JNLP agents pointed at controller; documented in Phase 3) |

Concurrency model: Jenkins `quietPeriod`, per-folder throttle (30 executors max via Docker Cloud
capacity), parallel monorepo service builds limited to 5 concurrent modules (`parallelism` config in
pipeline policy file).

### 7.3 Kernel & host prerequisites (production-grade)

```
vm.max_map_count = 524288              # SonarQube embedded Elasticsearch (hard requirement)
vm.swappiness = 1
fs.file-max = 1048576
fs.inotify.max_user_watches = 524288   # Alloy/log tails, GitLab
net.core.somaxconn = 4096
net.ipv4.ip_forward = 1                # Docker
user.max_user_namespaces ≥ 15000       # rootless BuildKit & unprivileged agent containers
```
Set via `/etc/sysctl.d/99-devsecops.conf` (Phase 2 `bootstrap.sh` writes and applies it).
Docker Engine ≥ 27.x, Compose v2 ≥ 2.32, `docker buildx` present. SELinux/AppArmor: keep enforcing;
only `buildkitd` requires `seccomp=unconfined` + `apparmor=unconfined` (documented trade-off,
Decision D-04) and runs on isolated networks with no host mounts except its cache directory.

---

## 8. Security Boundaries & Hardening Baseline

1. **Single ingress.** Only Traefik terminates TLS; backends never publish ports. HSTS + security
   headers middleware globally; IP allowlist on Vault/admin routes.
2. **No host Docker socket on the Jenkins controller.** Dynamic agents go through
   `tecnativa/docker-socket-proxy` with an explicit allow-list (`CONTAINERS=1`, `IMAGES=1`,
   `NETWORKS=1`, `POST=1`, everything else `0`). Image builds use rootless BuildKit, not DinD.
3. **Container hardening** (all custom images + compose entries): `no-new-privileges:true`,
   `cap_drop:[ALL]` (add back only what is proven necessary — e.g. `CHOWN/SETUID/SETGID` for
   GitLab/Nexus official images), `read_only: true` where the image supports it (prometheus,
   alertmanager, node-exporter, trivy runs, socket-proxy), non-root users (§6.3), pinned digests
   for custom base images in production (`image@sha256:` after first pull — Phase 2 script).
4. **Secrets flow.** Bootstrap secret (Vault root token, Jenkins admin, GitLab root, Nexus admin,
   Sonar admin) is generated by `bootstrap.sh` into `/opt/devsecops/secrets/` with `0600`,
   `chmod`-restricted, **never committed** (`.gitignore` + gitleaks pre-commit hook in this very
   repo). Jenkins stores them once as credentials and reads runtime secrets from Vault (AppRole,
   1 h TTL, response-wrapped). Application secrets reach Kubernetes via External Secrets Operator.
5. **Registry & supply chain.** Images pushed by digest; `latest` mutation disabled by Nexus
   cleanup + Kyverno `disallow-latest-tag`; cosign signature verified by Kyverno `verifyImages`
   before admission; SBOM archived and re-scanned nightly (Trivy cron in Phase 7).
6. **Security policy engine.** Central `security/policies/security-policy.yaml` (§10 of master
   spec) is loaded by the shared library; project overrides may only *tighten*, never relax,
   org-mandated gates; exceptions require owner + justification + approval + expiry, recorded in
   `security/policies/exceptions/` (validated JSON, audited in every pipeline run).
7. **RBAC mapping** (Phase 11 implements; Phase 1 defines): Platform Admin, DevOps Admin,
   Developer, Security Engineer, Release Manager, App Owner — mapped consistently across GitLab
   groups/roles, Jenkins matrix-auth, Nexus roles, Vault policies, K8s RBAC. Least privilege:
   Jenkins→K8s read-only SA; ArgoCD→GitOps repo read-only deploy key; GitOps writes only from the
   pipeline's short-lived Vault-issued token.
8. **Audit trail.** GitLab audit events; Jenkins audit-trail plugin → Loki; Vault audit device →
   Loki; Nexus audit (task log + request log); Kyverno policy reports; all dashboards in Grafana.

---

## 9. Architectural Decision Log (assumptions documented per §23 of the master spec)

| ID | Decision | Rationale / assumption |
|----|----------|------------------------|
| D-01 | Ship K3s Option B as reference; all ArgoCD config portable to Option A | Makes acceptance tests 12–16 reproducible; production sites reuse artifacts unchanged |
| D-02 | Traefik (not Nginx) as reverse proxy | Native Docker-provider discovery, middleware chain (IPAllowList, basicauth, rate-limit), SNI TLS routing for the Docker registry, ACME support |
| D-03 | GitLab CE 19.5 with **built-in Postgres/Redis** (omnibus), not externalized | Single-instance control plane; externalizing GitLab's PG is an EE-oriented HA pattern and adds containers without benefit here. Documented as scale-out path |
| D-04 | Rootless BuildKit daemon for image builds; docker-socket-proxy (allow-listed) only for agent lifecycle | Satisfies "no unrestricted socket on controller", "no unauthenticated TCP daemon"; BuildKit TCP is confined to `cicd-network` |
| D-05 | Warm agent pool (3 general/security/python) + Docker Cloud dynamic agents | "Don't run every agent permanently" while keeping cold-start < 60 s |
| D-06 | Nexus is the **only** image registry | Master-spec constraint; docker-group fronts hosted+proxy; promotion = same digest re-tag across env values |
| D-07 | SonarQube **Community Build** (26.10) | Branch/PR analysis is limited on Community: main-branch analysis + MR decoration via community tooling is out of scope; pipeline runs full analysis on `main`/`develop` and lightweight PR gate via `sonar.qualitygate.wait` on merge results. If the site licenses Developer Edition, swap the image tag — all scanner config is edition-agnostic |
| D-08 | PostgreSQL 17 dedicated container for SonarQube | Required by SonarQube server (embedded H2 is not supported for production) |
| D-09 | Vault dev-mode **never** used; file/raft storage + auto-unseal via transit-seal or documented manual unseal with shamir key ceremony in lab | Enterprise requirement; bootstrap script performs init + key split 3/5 and stores recovery material off-host |
| D-10 | Alloy instead of Promtail | Promtail is EOL (Nov 2024); Alloy is Grafana's supported successor and is what current Loki docs ship |
| D-11 | Jenkins GitLab **Branch Source** multibranch (not per-repo freestyle) + shared library `microservicePipeline` | Master-spec §8 |
| D-12 | Rollback = GitOps re-pin of previous digest (primary), `argocd app rollback` (secondary) | Keeps Git as single source of truth; timeout alone never triggers rollback — pipeline queries ArgoCD/K8s health first (§2.2 step 6) |
| D-13 | Single `PLATFORM_DOMAIN` with subdomain routing; lab uses `/etc/hosts` + internal CA | Avoids inventing unsupported wildcard/cloud dependencies |
| D-14 | Redis only where required: GitLab omnibus (internal), Jenkins plugin caching (in-memory) — **no standalone Redis container** | Master spec: "Redis only if a documented component requires it" — none does in this topology |
| D-15 | All patch-level pins for exporters/alertmanager/alloy/scanners are finalized by `scripts/validate.sh --versions` at each phase bootstrap | Avoids stale pins; validation output recorded in phase completion checklist |
| D-16 | Dedicated internal `agents-network` for all build agents (Phase 3) | docker-plugin attaches a template to exactly ONE network; a dedicated plane also gives agents least-privilege reachability (CI services only, no direct internet — Nexus is the sole dependency upstream). Warm agents that legitimately need egress (general → ArgoCD/K8s APIs; security → scanner DB updates) additionally join `artifact-network` / `security-network` |
| D-17 | Dynamic agents use the docker-plugin **JNLP connector** (verified in plugin sources), so the socket-proxy `EXEC` permission stays DENIED | Attach-connector would require `docker exec` into agent containers — rejected; JNLP containers connect back to the controller on the internal network instead |
| D-18 | GitLab webhooks target Jenkins over the INTERNAL scm-network (`http://jenkins:8080/project/…`) with `allow_local_requests_from_web_hooks_and_services=true` | Avoids hairpinning webhook traffic through Traefik/TLS and removes the need for GitLab to trust the internal CA for webhook delivery; risk contained: only this GitLab makes private-range calls, only to its own networks. Group webhooks are Premium → per-project hooks via `add-webhook.sh` |
| D-19 | GitLab CE tier limitations are handled by attempting Premium APIs and degrading loudly (documented in security.md §2.2) | Merge-approval rules, CODEOWNERS enforcement, push rules and group webhooks are Premium. CE baseline = protected branches/tags + "pipelines must succeed" + MR-only flow + CODEOWNERS files seeded from day one, so a license upgrade activates enforcement with zero script changes |
| D-20 | Quality-gate enforcement is **scanner-side**: every analysis runs with `sonar.qualitygate.wait=true` (+timeout 600 s); the global SonarQube→Jenkins webhook is created best-effort with graceful degradation | Scanner-side waiting works on ALL editions (including Community Build, where webhook support varies) and makes the gate a hard build failure without depending on webhook round-trips. The webhook (HMAC secret `SONAR_WEBHOOK_TOKEN`, JCasC `webhookSecretId`) remains for notifications/`waitForQualityGate` if available. CE has no branch analysis → `runSonarAnalysis` isolates non-main branches into separate project keys (`repo--service--branch`) |
| D-21 | Nexus repository layout: proxies cache ALL upstreams (agents never reach the internet directly, D-16); hosted repos hold platform artifacts; consumers use GROUP URLs only. Cleanup policies bind to **proxies exclusively**; docker-hosted and maven-releases are never auto-cleaned | docker-hosted images are referenced by immutable digest from gitops-repository — automatic deletion could break a deployed environment; release lifecycle is an explicit process (Phase 9+). `docker-group` connector listens on :8085, matching the Traefik TCP router (`registry.<domain>`, TLS terminated at Traefik). Nexus exposes no REST API for scheduled tasks → the two admin tasks ("Cleanup service", "Remove snapshots") are documented one-time UI steps |
| D-22 | Team CI onboarding = **GitLab Organization Folders** (gitlab-branch-source, D-11) seeded via JCasC Job DSL, with `manageWebHooks=false`; project webhooks are registered at onboarding by the platform admin (`gitlab/scripts/add-webhook.sh`, root token) and an hourly org scan is the event safety net | Auto-discovery: new repos with a Jenkinsfile become multibranch jobs with zero Jenkins changes. Hook management via the plugin would require `jenkins-ci` to be Maintainer on every team group (GitLab requires Maintainer for project hooks) — rejected on least-privilege grounds; onboarding stays a deliberate, audited platform-admin action. Secret-token verification on incoming hooks matches `GITLAB_WEBHOOK_TOKEN` |
| D-23 | Image identity: `registry.<domain>/<team>/<service>:<branch>-<sha9>-<build>`, pushed via rootless BuildKit (`--profile build`), digest resolved with `crane` after push and recorded per service (`env.IMAGE_DIGEST_<SVC>` + `reports/image-<svc>.json`) | No `latest` tag is ever created (master spec); unique tags make every push idempotent and traceable to a commit+build; the DIGEST is the promotion unit across environments (Phase 8 pins it in gitops-repository). agent-general bakes the platform CA so buildctl/crane trust the Traefik-terminated registry endpoint. Build-time repo configuration is generated per build (`RepoConfig` → `.platform/`) instead of baked into agents — credentials never enter images, and Nexus endpoints stay centrally governed by platform-config.yaml |
| D-24 | Security scanners run on `agent-security` and stay inside the no-internet boundary (D-16): semgrep rulesets baked at image build time (`/opt/semgrep-rules`), trivy vuln/java DBs pulled at runtime through Nexus (`ghcr-proxy` member of `docker-group`), OWASP Dependency-Check NVD mirror maintained HOST-SIDE (`security/scripts/20-dependency-check-db.sh`, nightly cron/systemd) into `${DATA_ROOT}/security/dependency-check` → mounted at `/owasp-dc`, scans run `--noupdate` | Every alternative (direct egress for scanners, DB baked into images, per-build downloads) either breaks D-16 or makes vulnerability data stale/unauditable. The DC CLI version and the updater image version are pinned to the SAME value (`DEPENDENCY_CHECK_VERSION=12.1.0`) for H2 schema compatibility. Image-stage security steps allocate `node('security')` inside the general-node image stage — different labels, so no warm-pool executor contention. Findings are normalized (`FindingGate`) and gated ONLY by SecurityPolicy (block_on_* flags + validated exception register) — scanner exit codes never decide policy |
| D-25 | Image signing key lifecycle: platform-static cosign keypair generated by `security/scripts/10-cosign-keys.sh` into `secrets/cosign/` (private key also base64'd into `secrets/cosign.env` → JCasC credentials); signatures are created BY DIGEST; Phase 11 migrates the key into Vault (transit, rotation) without changing the pipeline steps | Signing must work before Vault is wired (Phase 11); the credential indirection (`cosign-signing-key` / `-password`, fail-closed placeholders) means the Phase 11 migration is a value swap, not a code change. Signing by digest (never tag) makes the signature travel with the promoted artifact; `cosign.pub` is published to the Kyverno `verifyImages` policy in Phase 8 so clusters admit only platform-signed digests |
| D-26 | GitOps "render & commit": CI renders `microservice-standard` + app values into `applications/<svc>/base/manifests.yaml` and commits; environments are Kustomize overlays (namespace, replicas, labels, `images:` digest pin, patches); ArgoCD syncs plain kustomize paths | Git shows the exact manifests that will be applied (ops-reviewable diffs), deployment is deterministic (pinned helm in CI, no repo-server renderer drift), and digest promotion/rollback is a one-line overlay diff. Trade-off: rendered output is committed — it is CI-managed (`render-app.sh` reproduces it), hand-edits are review-rejected |
| D-27 | Lab cluster exposure & connectivity: K3s with traefik+servicelb DISABLED (platform Traefik owns :80/:443), ArgoCD on NodePort 30443 (self-signed, CLI `--insecure`); cluster→platform via node /etc/hosts (CoreDNS NodeHosts) + platform CA (containerd, argocd cert add-git, Kyverno SSL_CERT_FILE, ESO caBundle); docker.io/quay.io/ghcr.io mirrored through registry.<domain> with Nexus basic auth in registries.yaml (0600) | One host must run both planes without port conflicts; DNS/CA distribution follows the same internal-ca model as the agents; mirroring extends D-16 (Nexus-only upstream) to cluster pulls, with auth at containerd level so workload pods need no imagePullSecrets |
| D-28 | Admission control: Kyverno (Enforce) — `verify-image-signature` (cosign verifyImages against the platform public key injected INLINE from secrets/cosign/cosign.pub) + `require-digest-pinning` (`registry.<domain>/*@sha256:*` pattern on all containers); platform namespaces excluded | Closes the Phase 7 signing loop at runtime: unsigned or mutable-tag pods cannot be admitted even if git is tampered with. Inline key (Kyverno verifyImages cannot read K8s secrets) makes `cosign-public-key.sh` the rotation runbook |
| D-29 | Secret flow: chart values carry key NAMES → ExternalSecret (ESO v1 API) → ClusterSecretStore `vault-cluster-store` → Vault KV v2 `secret/apps/<svc>/<name>`; Vault Kubernetes auth mount per cluster (`kubernetes-<name>`, TokenReview via dedicated SA), role `eso-reader` bound to SA external-secrets:eso-vault-auth, policy reads `apps/*` ONLY | No static Vault token in the cluster, per-cluster trust boundaries (multi-cluster), least-privilege read scope; the gitops repo stays secret-free by construction (gitleaks-clean) |

---

## 10. Environment Variable Plan (implemented as `.env.example` in Phase 2)

Namespace-prefixed variables, consumed by compose interpolation; **no secrets in `.env`** —
`.env` holds domains, versions, sizing, paths; secrets live in `/opt/devsecops/secrets/` + Vault.

| Group | Variables |
|-------|-----------|
| Platform | `PLATFORM_DOMAIN`, `K8S_DOMAIN`, `TLS_MODE` (internal-ca/letsencrypt), `DATA_ROOT`, `TZ` |
| Versions | `GITLAB_VERSION`, `JENKINS_VERSION`, `SONARQUBE_VERSION`, `NEXUS_VERSION`, `VAULT_VERSION`, `TRAEFIK_VERSION`, `PROMETHEUS_VERSION`, `GRAFANA_VERSION`, `LOKI_VERSION`, `K3S_VERSION`, `ARGOCD_VERSION` … |
| UIDs | `JENKINS_UID/GID`, `SONAR_UID`, `NEXUS_UID(200)`, `VAULT_UID(100)` |
| Sizing | `GITLAB_MEM_LIMIT`, `JENKINS_HEAP`, `SONAR_JVM*`, `NEXUS_HEAP`, `PROM_RETENTION`, `LOKI_RETENTION`, `AGENT_POOL_SIZE`, `MAX_CONCURRENT_BUILDS` |
| Integration endpoints (internal DNS) | `GITLAB_URL=http://gitlab`, `JENKINS_URL=http://jenkins:8080`, `SONAR_URL=http://sonarqube:9000`, `NEXUS_URL=http://nexus:8081`, `REGISTRY_URL=registry.${PLATFORM_DOMAIN}`, `VAULT_ADDR=http://vault:8200` |
| Notifications | `SMTP_HOST/PORT/FROM`, `SLACK_WEBHOOK_VAULT_PATH`, `TEAMS_WEBHOOK_VAULT_PATH` (webhook URLs fetched from Vault at runtime, not stored in env) |

---

## 11. Phase 1 Validation (prerequisites, commands, expected output)

### 11.1 Host prerequisites checklist

```bash
# OS/kernel
uname -r                                  # expect >= 5.15 (Ubuntu 22.04/24.04, RHEL 9.x)
docker version --format '{{.Server.Version}}'   # expect >= 27.x
docker compose version                    # expect v2.32+
docker buildx version                     # expect present
sysctl vm.max_map_count                   # expect >= 524288 (set by bootstrap in Phase 2)
# Resources
nproc && free -g && df -h /mnt/data       # compare against §7.2 profile
# Network
ss -tlnp | grep -E ':(80|443|2222)\b'     # expect EMPTY before deployment (no conflicts)
```

### 11.2 Deliverable validation

```bash
cd devsecops-platform
find . -type d | wc -l                    # expect 60+ directories from §19 structure
test -f documentation/architecture.md && echo "architecture OK"
```

### 11.3 Failure scenarios considered in this design

| Failure | Architectural mitigation |
|---------|--------------------------|
| Host port conflict (80/443/2222 in use) | Preflight `ss` check in `bootstrap.sh`; configurable `HTTP_PORT/HTTPS_PORT/SSH_PORT` in `.env` |
| SonarQube crash-loops on ES bootstrap | `vm.max_map_count` sysctl + uid-mapped data dir + init check in compose `depends_on: condition: service_healthy` |
| Nexus OOM under image push load | Hard heap env (`INSTALL4J_ADD_VM_PARAMS`), memory limit §7.1, blob-store disk quota alerts (Phase 10) |
| Jenkins controller overloaded by builds | Zero executors on controller, all work on labeled agents, throttled Docker Cloud capacity |
| Registry TLS rejection by docker clients | `/etc/docker/certs.d/registry.<domain>/ca.crt` distributed by bootstrap; Traefik SNI router documented |
| Backup of live DB files inconsistent | Only tool-native dumps used: `gitlab-backup create`, `pg_dump` (Sonar), Nexus backup task, `vault raft snapshot`, Prometheus snapshot API (§12) |
| Single-host total loss | Restic off-host repo + documented RTO/RPO (§12); GitOps repo in GitLab is itself backed up |

### 11.4 Troubleshooting entry points (detailed runbooks land with each phase)

```bash
docker compose ps                                   # health of every container
docker compose logs --tail=100 <service>            # per-service logs (also in Loki once Phase 10 is up)
docker network inspect devsecops-platform_<net>     # verify membership against §4.1
curl -vk https://jenkins.${PLATFORM_DOMAIN}/login   # proxy chain check
```

---

## 12. Backup & Recovery Architecture (design fixed here, implemented Phase 11)

| Component | Method (consistent, tool-native) | Frequency | RPO | RTO |
|-----------|----------------------------------|-----------|-----|-----|
| GitLab | `gitlab-backup create` + `/etc/gitlab` config & secrets tar | daily 01:00 | 24 h | 2–4 h |
| Jenkins | JCasC + shared library in Git (source of truth); `jenkins-home` restic incremental; credentials re-derivable from Vault | daily | 24 h | 1 h |
| SonarQube | `pg_dump` (custom format) + `sonarqube/extensions` | daily | 24 h | 1 h (rescan rebuilds analysis data) |
| Nexus | Scheduled **backup task** (db + blob store) to `/mnt/data/backups` → restic | daily | 24 h | 2–4 h (artifacts rebuildable from source except releases) |
| Vault | `vault operator raft snapshot save` after every policy change + daily; keys in sealed envelope off-host | daily + on change | ~0 (keys) / 24 h | 30 min (unseal + snapshot restore) |
| Prometheus/Grafana/Loki | Prometheus snapshot API; Grafana provisioning + db dump; Loki: accept data loss (logs re-derivable 14 d) | weekly | 7 d | 30 min |
| K3s/ArgoCD | GitOps repo **is** the backup; `k3s etcd/sqlite snapshot` weekly | weekly | 7 d | 1 h |

Off-host: restic repository at `${RESTIC_REPOSITORY}` (S3-compatible or SSH target), encryption key
stored **only** off-host + sealed copy in company password vault. `backups/staging` never holds
unencrypted data longer than the run.

---

## 13. Phase 1 Completion Checklist

- [x] Architecture and delivery flow defined (§2)
- [x] ArgoCD Option A/B boundary explicitly resolved — D-01 (§2.1)
- [x] Complete container inventory with **verified, pinned versions** (§3)
- [x] Network segmentation: 8 dedicated networks, internal-by-default (§4.1; agents-network added Phase 3, D-16)
- [x] Full communication matrix (§4.2) and hostname/routing plan (§4.3)
- [x] Host port exposure reduced to 443/80/2222 (§5)
- [x] Storage layout, ownership (uid/gid), capacity plan (§6)
- [x] Resource sizing: per-service limits + two host profiles + kernel prereqs (§7)
- [x] Security boundaries & hardening baseline (§8)
- [x] Decision log with documented assumptions D-01…D-15 (§9)
- [x] Environment variable plan (§10)
- [x] Validation commands + expected outputs (§11)
- [x] Failure scenarios & mitigations (§11.3)
- [x] Backup/DR architecture with RPO/RTO (§12)
- [ ] Phase 2 (Docker Compose infrastructure) — next

### D-30 — Progressive delivery as an in-chart opt-in Rollout (Phase 9)

Canary/blue-green via Argo Rollouts v1.10.1 (pinned install, lab replicas=1):
`rollout.enabled` switches the chart's workload kind; the FULL pod-template
lives in `_helpers.tpl` so Deployment and Rollout can never drift (same probes,
same securityContext, same digest pin — Kyverno/signature guarantees carry over
unchanged). Step lists are chart values, per-env tuned via overlay patches
(orders-api: 10s pauses in dev → 10/30/60/100 with 3×2m pauses in prod).
Blue-green keeps promotion AUTOMATIC-but-bounded (autoPromotionEnabled) so
`verifyDeployment` converges on `Healthy` within `verify.timeoutSec` — an
indefinite manual promotion would stall every pipeline; teams wanting a
human gate flip `acceptPaused: true` + pause `{}` deliberately. Kustomize CRD
gotchas solved once and documented (gitops.md §9.3): replicas via a
per-overlay `replicas-config.yaml` (built-in transformer excludes CRDs and has
no `kind:` field in v5.8.3; configurations files must live inside the overlay
root), pod-template LIST edits via JSON6902 (CRDs get JSON-merge semantics —
strategic `containers` patches clobber the whole list).

### D-31 — Smoke tests run FROM the CI agent via port-forward (Phase 9)

`runPostDeploy` executes newman (Postman collections) and k6 (threshold-driven)
discovered by convention (`tests/postman/*.postman_collection.json`,
`tests/k6/*.js`) in the service repo, against a `BASE_URL` resolved by
`kubectl port-forward` through the READ-ONLY verifier kubeconfig. Rejected
alternatives: in-cluster test pods/Jobs (needs pod-create RBAC on the verify
identity — breaks least privilege) and ingress-based URLs (not all envs expose
services; port-forward works uniformly). `pods/portforward create` is the
identity's ONLY active verb — reach to service ports, never exec into
containers. No tests discovered = LOUD skip with report
(`SKIPPED-NO-TESTS`), never silent, never failing (D-19). Local port =
`postDeploy.localPortBase + hash(slug)` so parallel services can't collide.
k6 exit 99 (thresholds breached) fails like any nonzero rc — thresholds ARE
the gate, no duplicate assertion logic in Groovy.

### D-32 — Automatic rollback = git-history digest revert (Phase 9)

On verify or smoke failure (`gitops.autoRollback: true`), `rollbackDeployment`
re-pins the PREVIOUS digest of the environment overlay — found by walking that
file's OWN git history (`git log -- <overlay>`, zeros placeholder ineligible)
— pushes `revert(gitops): rollback <svc>@<env> → sha256:… (<reason>) [skip ci]`
and waits for ArgoCD. GitOps-native: no `kubectl` mutation, no Helm rollback
history dependency, works for both workload kinds, and the audit trail is the
git log itself. The triggering build STILL FAILS — rollback restores the
service, never excuses the change; promotion of a later good digest simply
overwrites the revert commit. Fallback: no history (first deployment) →
explicit `DIGEST` param via `platform/gitops-promotion`. The same helper backs
manual rollbacks with an optional pinned digest.

### D-33 — SLOs: probe-style platform availability + Traefik success ratio, multi-window burn rates (Phase 10)

Two SLIs, both from data the platform ALREADY produces (no synthetic probers,
no per-service instrumentation): **platform availability** = `avg(up)` over the
five business-critical scrape targets (jenkins, gitlab-exporter, nexus, vault,
traefik), objective 99.5%/30d; **per-service HTTP success** = 1 − 5xx-ratio
through Traefik, objective 99.9%/30d. Alerting uses the SRE-workbook
multi-window multi-burn-rate pattern (14.4× on 5m+30m → page, 6× on 1h+6h →
ticket) recorded in `rules/slo.yml`, so pages mean "budget dies in 2 days",
never "one blip". A permanently-firing **Watchdog** heartbeat routes to a
no-op receiver — its absence is the meta-signal that the alerting path itself
is dead (external uptime systems assert on it via the Alertmanager API).

### D-34 — Notifications: two paths, file-based secrets, parse-safe placeholders (Phase 10)

Infrastructure alerts (Prometheus + Loki ruler) go through **Alertmanager**
receivers; pipeline events (master spec §16) go through Jenkins
**notifyResult/NotificationService** — both terminate on the same Slack /
Teams / SMTP endpoints, but neither depends on the other (a dead Jenkins must
still page; a dead Alertmanager must not lose build notifications). Secrets
are delivered as **files** (`api_url_file`, `webhook_url_file`,
`auth_password_file`, Prometheus `password_file`) mounted read-only from
`secrets/` — never inline in YAML that lives in git. Because both daemons
validate file contents at config load, bootstrap.sh writes every file from
day one with **parse-safe placeholders** (URL-shaped, host-shaped): configs
load, delivery fails per-message and is logged, processes stay healthy. One
script (`monitoring/scripts/20-configure-notifications.sh`) flips reality on:
real values → secret files + yq-updated smarthost/from/to + JCasC env +
per-channel `notifications.*.enabled` in platform-config (channels enable
only when actually configured — no fake "enabled" states) + SIGHUP reload.
Phase 11 swaps the script's input side to Vault; the file layout is already
the Vault-agent template shape.

### D-35 — Logs: noise dropped at the edge, alerts from the embedded ruler (Phase 10)

Alloy collects every compose container through the socket proxy (D-04) and —
new in Phase 10 — a `loki.process` stage **drops healthcheck/ping lines before
ingestion**: compose healthchecks emit every 30s per container and would
otherwise dominate Loki volume and poison error-rate log alerts. Loki's
monolithic mode runs the **embedded ruler** with file-based rules
(`monitoring/loki/rules/fake/`, tenant `fake` = auth disabled), alerting into
the SAME Alertmanager routes as metric alerts (severity drives routing). This
gives log-derived detection with zero extra services: failure modes that exist
only in text (OOM stack traces, vault seal messages, error-line spikes per
service) alert exactly like metric breaches. Rejected: a separate
promtail+ruler deployment (more moving parts for one tenant) and
Grafana-managed alerting (would fork alert state away from Alertmanager).

### D-36 — Vault as source of truth, files as bootstrappable fallback (Phase 11)

Platform operational secrets (notification endpoints, SMTP, cosign keypair) are
MIGRATED into `secret/platform/*` and exposed to Jenkins through an AppRole
(`jenkins-platform` policy: read `platform/{notifications,cosign}` ONLY —
application secrets stay ESO-exclusive) with **1h tokens / 4h max**, consumed
via the already-pinned hashicorp-vault-plugin (`withVault`, global
`vaultConfiguration` in JCasC). The `secrets/*.env` files REMAIN as the
cold-start fallback: a sealed Vault must not make the platform unbootable, and
JCasC interpolates env at controller start — before any Vault login could
exist. The honest trade: role-id/secret-id live in a 0600 env file
(`secret_id_ttl=0` deliberately — the controller needs boot-time identity
without an unwrap oracle); blast radius is bounded by the 1h token TTL +
read-only policy, and rotation is one script rerun + recreate. Audit device is
enabled (fail-closed on unwritable backend — intentional) and shipped to Loki
via an Alloy file tail (`service="vault-audit"`; tokens are HMAC-hashed by
Vault, so the stream is safe to store/query).

### D-37 — Two-layer backups: native consistent dumps + restic, one restore toolkit (Phase 11)

File-level restic alone cannot back up live databases consistently — so
`native-dumps.sh` stages component-consistent snapshots FIRST (vault raft
snapshot, `gitlab-backup create STRATEGY=copy`, `pg_dumpall --clean`, Nexus
`db.backup` task), all inside `DATA_ROOT`, and the restic layer (loop service +
on-demand `backup-now.sh`) captures everything as one repository with
retention/prune/sampled-check. Each component is optional-tolerant: a
not-running service skips with a warning — partial beats nothing.
`restore.sh` is the single recovery surface (files / vault-raft / gitlab /
sonar-db / all) with stop-the-world guards and confirmation prompts; the
bare-metal DR runbook (backup-recovery.md §5) is ordered so Vault unseal (with
the ORIGINAL off-host keys — never stored in the backup scope) precedes every
component restore, and the cluster side self-heals afterwards (ESO resyncs
from Vault, ArgoCD re-syncs from git). RPO ≤ 24h default / RTO ≈ 30 min per
component; observability data is explicitly loss-tolerant (dashboards+config
live in git). Off-host restic repositories are a documented production
requirement, not the default (local repo survives mistakes, not host loss).

### D-38 — Realm cutover as a one-for-one file swap (Phase 11)

JCasC cannot express conditional realm blocks, so the enterprise cutover ships
as `jenkins/optional-casc/10-security-{ldap,oidc}.yaml` mounted OVER
`10-security.yaml` at the SAME path — the controller never sees two
securityRealm definitions, and rollback is removing the volume line. The
six-role authorization matrix is realm-independent (maps principals; `user:` →
`group:` is the only delta). OIDC needs the `oic-auth` plugin — pinned
(4.731.v4932b_506e767, verified ≥2.539 vs platform 2.568.3) but COMMENTED in
plugins.txt so the default image stays lean; LDAP needs no pin (core-detached
plugin). Break-glass: OIDC kit enables the escape hatch reusing the bootstrap
admin password; LDAP kit documents the manager-DN recovery path.
