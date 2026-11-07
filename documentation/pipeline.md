# Pipeline Framework Guide

> Updated through Phase 6. Security gates (Phase 7), GitOps stages (Phase 8)
> and release strategies (Phase 9) extend this document as their flags flip in
> `platform-config.yaml`.

## 1. The one-pipeline contract

Every microservice repository contains exactly one Jenkinsfile:

```groovy
@Library('devsecops-shared-library') _

microservicePipeline(
    serviceName: 'payment-service',
    deploymentType: 'helm',
    environments: ['dev', 'qa', 'uat', 'prod']
)
```

All behavior is configured — never coded — in:

| File | Layer | Rules |
|------|-------|-------|
| `resources/config/platform-config.yaml` (library) | organization | stage flags, environments, agent labels, concurrency, notification channels, security floor |
| `devsecops.yaml` (service repo) | project | serviceName, language/buildTool hints, deploymentType, environments subset, `dependsOn`, **tighten-only** security overrides |
| `security-exceptions.yaml` (service repo) | project | time-boxed exceptions: id, tool, owner, justification, approvedBy, expires |

Overrides that weaken mandatory security sections (`secrets`, `sbom`,
`signing`) or turn any platform `block_on_*` flag OFF **fail the build** at
validation time (`PlatformConfig.validateOverrides`).

## 2. Stage model & incremental enablement

Stages are gated by flags in `platform-config.yaml`. A gated-off stage prints
`SKIPPED — stage implementation lands in Phase N` on every run; nothing is
ever silently absent.

| Stage | Flag | Activates |
|-------|------|-----------|
| Checkout | `checkout` | ✅ Phase 3 |
| Discovery & Validation | `discovery` | ✅ Phase 3 |
| Pre-build secrets scan | `secrets` | Phase 7 |
| Build / unit / integration tests | `build`, `unitTests`, `integrationTests` | ✅ Phase 6 |
| Sonar quality gate | `quality` | ✅ Phase 5 |
| SAST / dependency scan | `sast`, `dependencyScan` | Phase 7 |
| Package / image build | `package`, `imageBuild` | ✅ Phase 6 |
| Image scan / SBOM / sign | `imageScan`, `sbom`, `sign` | Phase 7 |
| Publish to Nexus | `publish` | ✅ Phase 6 |
| GitOps update / ArgoCD sync | `gitops`, `sync` | Phase 8 |
| Deployment verification / post-deploy | `verify`, `postDeploy` | Phase 9 |
| Final report + notifications | `report` | ✅ Phase 3 (channels activate Phase 10) |

## 3. Project discovery engine (`detectProject`)

Manifest-driven (never extension-driven), monorepo aware:

| Language | Manifests | Framework detection |
|----------|-----------|---------------------|
| python | `pyproject.toml`, `setup.py`, `requirements*.txt`, `Pipfile`, `poetry.lock` | fastapi / django / flask from manifest content |
| java | `pom.xml`, `build.gradle(.kts)` | `spring-boot` from build-file content |
| dotnet | `*.sln`, `*.csproj`, `global.json` | — |
| nodejs | `package.json` + lockfile → npm/pnpm/yarn | react, angular, vue, next, nuxt, svelte, express, nest from dependencies |

Rules:
- Every directory containing a manifest is a candidate service; npm workspace
  roots and Maven aggregator POMs (`<packaging>pom` + `<modules>`) are
  excluded unless they carry their own Dockerfile.
- `devsecops.yaml` metadata overrides inference (explicit `language`,
  `buildTool`, `dockerfile`, `serviceName`, `dependsOn`).
- **Selective builds**: on non-main branches, only services whose paths
  changed since `GIT_PREVIOUS_SUCCESSFUL_COMMIT` are built, **plus** services
  declaring `dependsOn` a changed shared component (configurable dependency
  mapping). Docs-only changes end the pipeline as `NOT_BUILT`.
- Parallel execution: up to `concurrency.maxParallelServices` (default 5)
  services in parallel, each on its language's agent label.
- Discovery output is archived as `reports/project-discovery.json`.

## 4. Agents

| Label | Provisioning | Toolchain |
|-------|-------------|-----------|
| `general` | warm (compose) | git, kubectl, helm v3.22.1, kustomize v5.8.3, buildctl, crane, yq, argocd CLI v3.4.8 |
| `python` | warm (compose) | CPython 3.12.16, poetry 2.5.1, build, sonar-scanner 8.3 |
| `security` | warm (compose) | trivy 0.76.1, gitleaks 8.30.1, semgrep 1.183.0, syft 1.55.0, cosign 3.1.4, kubescape 4.0.17 |
| `java-maven` | dynamic (Docker cloud) | JDK 21 + Maven 3.9.16 + sonar-scanner |
| `java-gradle` | dynamic | JDK 21 + Gradle 8.14.6 + sonar-scanner |
| `dotnet` | dynamic | .NET SDK 9.0.320 + dotnet-sonarscanner 12.0.0 |
| `node` | dynamic | Node 22.23.4 + corepack (npm/pnpm/yarn) + sonar-scanner |

Dynamic agents: created by the docker-plugin through the **allow-listed
socket-proxy**, attached to the internal `devsecops-agents` network (no direct
internet — dependencies flow through Nexus from Phase 5), connected back via
JNLP (no `docker exec`), destroyed after one build (`DockerOnceRetentionStrategy`
semantics of the plugin: one build per container).

## 5. Notifications

`notifyResult` composes the §16 field set (service, repository, branch,
commit, build number, image digest, environment, failure stage, build URL,
ArgoCD URL, quality gate, security summary) and dispatches to enabled
channels (email-ext / Slack / Teams webhooks). Webhook credentials stay
`SET_IN_PHASE_10` placeholders until provisioning; dispatch failures are
logged and **never** fail builds.

## 6. Extending the framework

- New stage step: add `vars/<step>.groovy`, wire into
  `microservicePipeline.dispatchStage`, add flag + phase annotation to
  `platform-config.yaml`.
- New language: add detection to `detectProject.classifyDir/inferLanguage`,
  an agent image, a cloud template, and a build pack in `buildApplication`
  (Phase 6 defines the build-pack interface).
- Never fork `microservicePipeline` per team — that is exactly what the
  master spec forbids; per-team differences belong in `devsecops.yaml`.

## 7. Language build matrix (Phase 6)

All dependency traffic is forced through Nexus by `RepoConfig` (writes
`.platform/` config per build; secrets stay in env-expansion formats wherever
the toolchain allows — see `src/org/company/devsecops/RepoConfig.groovy`).

| Language | Build (`buildApplication`) | Unit tests (`runUnitTests`) | Integration marker (`runIntegrationTests`) | Package (`packageApplication`) | Publish (`publishArtifact`) |
|----------|---------------------------|------------------------------|---------------------------------------------|--------------------------------|------------------------------|
| Java/Maven | `mvn -s <settings> -DskipTests clean install` (wrapper-aware) | `mvn test` + surefire JUnit | `maven-failsafe-plugin` in pom → `failsafe:integration-test verify` | `mvn package` → target/*.jar | `mvn deploy` → fallback `deploy:deploy-file` into maven-releases/snapshots (SNAPSHOT allowed on any branch) |
| Java/Gradle | `gradle -I <init> build -x test` (wrapper-aware) | `gradle test` + optional jacoco | task `integrationTest` (probed via `help --task`) | `gradle assemble` → build/libs/ | `publishAllPublicationsToNexusRepository` (init script injects the `nexus` repo, release/snapshot by version) |
| .NET | `dotnet restore/build -c Release` (NuGet.config in cwd) | `dotnet test` (JUnit logger if `JunitXml.TestLogger` referenced; coverage via XPlat) | `[Trait("Category","Integration")]` → `--filter Category=Integration` | `dotnet publish -o publish/`; `dotnet pack` when `IsPackable=true` | `dotnet nuget push → nuget-hosted` (release contexts only) |
| Python | venv + `pip install` (requirements.txt / pyproject, Nexus index) | `pytest --junitxml --cov` (exit 5 = no tests → skip) | `@pytest.mark.integration` → `pytest -m integration` | `poetry build` or `python -m build` → dist/ | twine/poetry → pypi-hosted (release contexts only) |
| Node.js | npm/pnpm/yarn frozen-lockfile install + `build` script if present | `<pm> test` (CI=true, jest-junit dir `reports/`) | `test:integration` script in package.json | `npm pack` → *.tgz | `npm publish → npm-hosted` (release contexts only) |

### Publication policy

* **Release context** = branch `main`/`master`, `rel-*`, or a tag build.
* Java SNAPSHOT versions may publish from any branch (maven-snapshots only).
* Everything else on feature branches: explicit logged skip — release repos
  never receive unreviewed artifacts. Images ARE still built+pushed on every
  branch (by digest, uniquely tagged) so dev/qa environments can consume them.

### Container images (D-23)

* `buildContainer` runs on `agent-general` → rootless BuildKit
  (`buildkitd`, compose profile `build`, `tcp://buildkitd:1234`).
* Reference: `registry.<domain>/<team>/<service>:<branch>-<sha9>-<build>` —
  **no `latest` tag is ever created**; the pushed **digest** (`crane digest`)
  is the artifact identity recorded in `reports/image-<svc>.json` and
  `env.IMAGE_DIGEST_<SVC>` (Phase 8 pins exactly this value in GitOps).
* Docker build-args injected: `SERVICE_NAME`, `GIT_COMMIT`, `BUILD_NUMBER`,
  `BASE_REGISTRY` (Dockerfiles may pull base images through the registry).
* Registry TLS: agent-general trusts the platform CA (baked by
  `scripts/build-images.sh` at image build time).

### Agent/workspace topology (Phase 6 fix)

* Delivery stages are `agent none`; `runServiceStage` allocates the node per
  service (language agent / `security` / `general`) — no nested allocations,
  no warm-pool executor contention.
* Checkout `stash`es the source (`'source'`); every per-service node
  `unstash`es it — stages never depend on landing on the same agent.
* Monorepos: up to `concurrency.maxParallelServices` (5) services per group,
  each in an isolated workspace (Jenkins `@N` workspace allocation).

### Team/repository onboarding (Phase 6, D-22)

1. Create the project under `teams/<team>` in GitLab (group membership grants
   `jenkins-ci` clone rights automatically).
2. Add the standard Jenkinsfile (`@Library('devsecops-shared-library') _` +
   `microservicePipeline(serviceName: ...)`) — see library `examples/`.
3. The organization folder scan (hourly, or "Scan … now" in the UI) creates
   the multibranch job `teams/<team>/<repo>`.
4. Platform admin registers instant triggers:
   `./gitlab/scripts/add-webhook.sh teams/<team>/<repo> teams/<team>/<repo>`
5. New TEAM: create the GitLab group, add the slug to `TEAMS` in
   `jenkins/casc/60-jobs.yaml`, reload JCasC.

## 8. Security gates (Phase 7)

### Execution map

| Stage (flag) | Step | Agent | Tool(s) | Policy tool key |
|--------------|------|-------|---------|-----------------|
| Pre-Build Secrets Scan (`preBuildSecurity`) | `scanSecrets(preBuild:true)` | security | gitleaks `--no-git --redact` | `secrets` |
| Security Gates (`sast`) | `runSAST` | security | semgrep (baked offline rules) | `sast` |
| Security Gates (`dependencyScan`) | `runDependencyScan` | security | trivy fs + OWASP DC (`--noupdate`, `/owasp-dc`) | `dependencies` |
| Security Gates (`secrets`) | `scanSecrets` | security | gitleaks (skipped if pre-build ran) | `secrets` |
| Image stage (`imageScan`) | `scanContainer` | security (inner node) | trivy image **by digest** (`vuln,secret`) | `container` |
| Image stage (`sbom`) | `generateSBOM` | security (inner node) | syft → CycloneDX + SPDX, → raw-hosted | `sbom.required` |
| Image stage (`sign`) | `signImage` | security (inner node) | cosign sign **by digest** | `signing.required` |

### Verdict pipeline (single enforcement point)

```
scanner JSON ─▶ normalize {id, severity, detail(log-safe)} ─▶ FindingGate.evaluate
                                                                 │ policy disabled → explicit SKIP
                                                                 │ active exception (id OR altId) → ALLOWED + logged w/ expiry
                                                                 │ block_on_<severity> → BLOCKED: build fails, ≤15 ids listed
                                                                 └ else → reported + counted
                     verdict → reports/security-verdict-<svc>.json (archived)
```

Severity normalization: CVSS scores → bands (≥9 critical, ≥7 high, ≥4 medium);
semgrep ERROR→high, WARNING→medium, INFO→low (configurable in
`platform-config.yaml security.severityMapping`).

### Exception register (recap — validated EVERY run)

`security-exceptions.yaml` beside the service: `id` (CVE / semgrep check_id /
gitleaks RuleID or Fingerprint), `tool` (`secrets|sast|dependencies|container`),
`owner`, `justification`, `approvedBy`, `expires` (ISO-8601). Missing fields ⇒
build fails; expired ⇒ ignored with a warning, findings gate again. There is no
mechanism to silence a finding outside this register — by design (master §10).

### Offline data flows (D-24)

* semgrep rules: baked at agent-image build (`/opt/semgrep-rules`) — refresh =
  rebuild image (pinned, auditable).
* trivy DBs: `TRIVY_DB_REPOSITORY=registry.<domain>/aquasecurity/trivy-db`
  (docker-group → ghcr-proxy → ghcr.io, cached in Nexus).
* NVD: host-side `20-dependency-check-db.sh` (nightly) → `/owasp-dc` volume;
  agents scan with `--noupdate`.

---

## 9. GitOps & Deploy (Phase 8)

Stage runs when flag `gitops` is ON, on **agent-general** (helm/kustomize/yq/
argocd CLI pinned there), for every service in the build — after Publish:

```
GitOps & Deploy
├─ updateGitOps          (flag: gitops)
│   1. clone gitops-repository          http://gitlab/… (askpass auth — the
│      credential gitops-commit-token never touches the URL/.git config/logs)
│   2. helm template <slug> helm-charts/microservice-standard
│        -f applications/<slug>/values.yaml  →  base/manifests.yaml   (D-26)
│      (deploymentType=kustomize → base is team-managed, render skipped)
│   3. yq: overlays/<env>/kustomization.yaml images[name==<repo>].digest
│        = IMAGE_DIGEST_<slug>   (fails loudly if the entry is missing)
│   4. commit + push main (rebase-retry ×3; "[skip ci]"; empty diff = no commit)
│   → env GITOPS_APP_<slug>=<slug>-<env>, GITOPS_ENV_<slug>
│   → reports/gitops-update-<slug>.json (archived)
└─ deployApplication     (flag: sync)
    argocd app wait <slug>-<env> --sync --health --timeout <syncTimeoutSec>
    (CLI env: ARGOCD_SERVER_URL/ARGOCD_AUTH_TOKEN/ARGOCD_OPTS from
     secrets/argocd.env; account jenkins-cd — RBAC: applications get/sync ONLY)
    on failure: prints `argocd app get` diagnostics, then fails the build
    → env DEPLOY_ENVIRONMENT=<env> → reports/deploy-<slug>.json
```

**Target environment**: builds deploy to `gitops.defaultEnvironment` (dev).
qa/uat/prod are promotion-only — job **platform/gitops-promotion**
(`promoteDigest`): reads the source overlay's pinned digest (rejecting the
zeros placeholder), pins it into the target overlay, pushes, waits. Explicit
`DIGEST` parameter = rollback/hotfix (D-12). Both steps are fail-closed on
placeholder credentials with the exact host-side fix in the error message.

**Why the same digest everywhere**: the promoted artifact is the exact bytes
that passed imageScan/sbom/sign — Kyverno re-verifies the cosign signature at
admission in the target cluster (gitops.md §5), so git tampering alone cannot
deploy an unsigned image.

Verify/postDeploy stages remain flag-OFF until Phase 9 (`verifyDeployment`
will consume the read-only kubeconfig from `secrets/k8s.env`).

---

## 10. Verify & Post-Deploy (Phase 9 — pipeline complete: all stages active)

One stage group (`verify`), two independently flag-guarded steps, on
**agent-general**, per service (source stashed in Phase 6 is available — smoke
tests are discovered from the service repo):

```
Verify & Post-Deploy           when: verify || postDeploy flag
├─ verifyDeployment            (flag: verify)   — cluster ground truth, READ-ONLY kubeconfig
│   0. namespace exists (ArgoCD CreateNamespace)
│   1. workload detect: Rollout (argoproj.io) takes precedence over Deployment
│      • Deployment → kubectl rollout status (--timeout slices in a poll loop)
│      • Rollout    → poll .status.phase: Healthy=pass, Degraded=fail-fast
│                     (status.message included), Paused-at-timeout=fail unless
│                     verify.acceptPaused (keep canary pauses BOUNDED)
│   2. readyReplicas == spec.replicas
│   3. IDENTITY: every pod image endsWith @<IMAGE_DIGEST_<slug>> — what runs is
│      exactly what was scanned+signed this build; else at minimum digest-pinned
│   4. pathology: CrashLoopBackOff/ImagePullBackOff/CreateContainerConfigError/
│      FailedMount/… → FAIL         5. Warning events → context in report
│   6. ExternalSecrets Ready=True (ESO→Vault chain part of deploy health)
│   → env VERIFY_RESULT_<slug> · reports/verify-<slug>.json
└─ runPostDeploy               (flag: postDeploy) — smoke tests vs LIVE service
    discover: <svc.path>/tests/postman/*.postman_collection.json → newman
              <svc.path>/tests/k6/*.js                          → k6 (thresholds)
    BASE_URL: params/env/config postDeploy.baseUrl, else kubectl port-forward
              svc/<slug> (local port = localPortBase + slug-hash, parallel-safe;
              pods/portforward is the verifier identity's ONLY active verb)
    none found → LOUD skip (report SKIPPED-NO-TESTS; never silent, never fail)
    → reports/postdeploy-<slug>.json + native newman/k6 JSON reports
```

**Automatic rollback (D-32)** — on verify or smoke failure with
`gitops.autoRollback: true` (org default): `rollbackDeployment` walks the
overlay file's OWN git history (`git log -- <overlay>`), re-pins the previous
real digest (zeros placeholder never eligible), pushes
`revert(gitops): rollback <slug>@<env> → sha256:… (<reason>)` and waits for
ArgoCD. The build STILL fails; every rollback is an auditable commit. Manual
equivalent: `platform/gitops-promotion` with explicit `DIGEST`.

**Progressive delivery (D-30)**: apps with `rollout.enabled: true` deploy as
Argo Rollouts canaries/blue-greens; the pipeline treats them transparently
(verify polls `phase`), and ArgoCD's native Rollout health keeps `sync`
semantics unchanged. Environment-tuned step lists live in overlay patches
(orders-api: 10s pauses in dev → 3×2m staged canary in prod).

### 10.1 Troubleshooting (Verify & Post-Deploy)

| Symptom | Cause | Fix |
|---|---|---|
| `verifyDeployment` fails: "Paused at timeout" | Rollout canary/blue-green pause exceeds `verify.timeoutSec` or is unbounded | Keep pauses bounded in overlay step patches (orders-api pattern), raise `verify.timeoutSec`, or deliberately set `verify.acceptPaused: true` |
| Verify fails with `Degraded` + `status.message` | New ReplicaSet can't schedule/pull | Message is in the report + build log; pathology scan names the pod reason (ImagePullBackOff → check digest/tag in overlay; FailedMount → check ExternalSecret/ConfigMap) |
| "identity check failed: pod runs …" | Pod image ≠ `IMAGE_DIGEST_<slug>` (stale pod or bad pin) | Usually an un-pinned tag; ensure overlay digest patch applied — auto-rollback fires next |
| port-forward never comes up | Service not of type ClusterIP/NodePort on `ports[0]`, or ns wrong | Set `postDeploy.baseUrl` (or `POSTDEPLOY_BASE_URL_<slug>` env) — e.g. ingress URL for prod |
| newman/k6 not discovered | Tests outside conventions | Move to `tests/postman/*.postman_collection.json` / `tests/k6/*.js` inside the service path (report says `SKIPPED-NO-TESTS`) |
| Rollback fails: "no previous digest" | First-ever deployment of that env (only zeros placeholder in history) | Nothing to roll back to — fix forward, or pin explicitly: `rollbackDeployment(service:…, env:…, digest:'sha256:…')` |
| `replicas` transformer error on Rollout | Built-ins exclude CRDs; `kind:` field doesn't exist in kustomize v5.8.3 | Per-overlay `replicas-config.yaml` + `configurations:` (file must live inside the overlay dir) — see gitops.md §9.3 |
| Patch wiped image/probes | Strategic patch on CRD pod-template list = JSON-merge replace | JSON6902 ops targeting `/spec/template/spec/containers/0/…` |

---

## 11. Notifications from the pipeline (Phase 10, master spec §16)

`notifyResult` (fail-safe, usable in `post{}`) dispatches to the channels
enabled in `platform-config.yaml → notifications` — flipped per channel by
`monitoring/scripts/20-configure-notifications.sh` when real endpoints exist
(Slack webhook, Teams Workflows webhook, SMTP via the JCasC mailer).
Every message carries the full §16 context: service, repository, branch,
commit, buildNumber, imageDigest, environment, qualityGate, securitySummary,
failureStage, buildUrl, argocdApplicationUrl.

Events and where they fire:

| Event | Fired by |
|---|---|
| build_completed / build_failed | microservicePipeline `post{always{}}` |
| deployment_started / deployment_completed | deployApplication (sync path) |
| **deployment_failed** | verifyDeployment / runPostDeploy — the moment the verdict is in, BEFORE auto-rollback noise |
| **rollback_executed** | rollbackDeployment — automatic AND manual rollbacks (digest attached) |
| quality_gate_failed | runSonarAnalysis gate-wait failure |
| critical_vulnerability | security gate steps on CRITICAL findings |
| container_published | buildContainer/publish path |
| release_approved | promotion job approvals |

The infrastructure-side twin (Prometheus/Loki alerts → Alertmanager → the same
Slack/Teams/SMTP endpoints) is documented in `observability.md` §6 — the two
paths are deliberately independent: a dead Jenkins still pages on-call, and a
dead Alertmanager never loses build notifications.
