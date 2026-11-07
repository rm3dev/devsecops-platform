# devsecops-shared-library

The single pipeline framework for every microservice (master spec §8).
Registered globally in Jenkins via JCasC (`jenkins/casc/50-unclassified.yaml`)
as `devsecops-shared-library`, loaded from the GitLab project
`platform/devsecops-shared-library` (created in Phase 4 from this directory).

## Usage (all repositories — identical Jenkinsfile)

```groovy
@Library('devsecops-shared-library') _

microservicePipeline(
    serviceName: 'payment-service',
    deploymentType: 'helm',
    environments: ['dev', 'qa', 'uat', 'prod']
)
```

## Layout

```
vars/                                   pipeline steps
  microservicePipeline.groovy           the standard pipeline (stages 1–20)
  detectProject.groovy                  manifest-driven discovery + monorepo
                                        selective builds (changedOnly)
  validateProject.groovy                contract validation (fail fast)
  notifyResult.groovy                   §16 notifications (fail-safe)
src/org/company/devsecops/              reusable classes
  PlatformConfig.groovy                 layered config + tighten-only overrides
  SecurityPolicy.groovy                 policy engine + exception register
  NotificationService.groovy            email/slack/teams dispatch
  PipelineLogger.groovy                 structured [devsecops][svc][stage] logs
resources/config/platform-config.yaml             stage flags, environments, labels
resources/security-policy-default.yaml  organization security floor
examples/                               Jenkinsfile, devsecops.yaml,
                                        security-exceptions.yaml templates
```

## Incremental enablement (the phase contract)

Stages activate via `resources/config/platform-config.yaml` flags — never by editing
service repositories. Current status: `checkout`, `discovery`, `report` ON;
build/test/package/image/publish flip in Phase 6, quality in Phase 5,
security gates in Phase 7, GitOps/sync in Phase 8, verify/post-deploy in
Phase 9. A gated-off stage prints `SKIPPED — stage implementation lands in
Phase N` on every run (visible, never silent).

## Versioning

- `main` is the default version (JCasC `defaultVersion: main`).
- Breaking changes require a `vN` tag; repositories pin via
  `@Library('devsecops-shared-library@v2') _` only during migration windows.

## Project conventions consumed by Phase 6 steps

The pipeline is convention-driven — adopt these and every stage works with zero
per-repo configuration:

| Area | Convention |
|------|------------|
| Jenkinsfile | exactly `examples/Jenkinsfile` (library import + `microservicePipeline(serviceName: …)`) |
| Java/Maven | wrapper (`mvnw`) optional; `distributionManagement` optional (fallback: `deploy:deploy-file` into Nexus); failsafe plugin ⇒ integration tests run |
| Java/Gradle | `maven-publish` plugin ⇒ `publishAllPublicationsToNexusRepository` works (repo injected by platform init script); task `integrationTest` ⇒ integration tests run; jacoco ⇒ coverage imported by Sonar |
| .NET | `*.sln` at service root; reference `JunitXml.TestLogger` for JUnit output; `coverlet.collector` for coverage; `[Trait("Category","Integration")]` ⇒ integration tests run; `<IsPackable>true</IsPackable>` ⇒ nupkg published |
| Python | `requirements.txt` (runtime deps) and/or installable `pyproject.toml`; `requirements-dev.txt` for test deps; `pytest` + `pytest-cov` expected for unit tests; `@pytest.mark.integration` ⇒ integration tests run; poetry projects: `poetry.lock` + `poetry build/publish` used automatically |
| Node.js | lockfile decides pm (`package-lock.json`/`pnpm-lock.yaml`/`yarn.lock`); scripts: `build` (optional), `test` (unit), `test:integration` (optional); `jest-junit`/`mocha-junit-reporter` writing to `reports/` ⇒ results visible in Jenkins |
| Images | `Dockerfile` (or `Dockerfile.*` — first match) in the service dir; may use `ARG BASE_REGISTRY` to pull base images through the platform registry |
| Sonar | stable project keys: `extra.sonarProjectKey` in `devsecops.yaml`; default key = `<repo>--<service>[--branch]` (Community Build isolation) |

## Security gates (Phase 7)

* Findings never gate on scanner exit codes — `FindingGate` applies
  `resources/security-policy-default.yaml` (tightenable per project) and the
  exception register. One verdict file per service:
  `reports/security-verdict-<svc>.json`.
* Exception register (`security-exceptions.yaml` next to the service — see
  `examples/security-exceptions.yaml`): `id` matches CVE-IDs (dependencies /
  container), semgrep `check_id`s (sast), or gitleaks RuleID/Fingerprint
  (secrets); `tool` must be one of `secrets|sast|dependencies|container`;
  `owner`, `justification`, `approvedBy`, `expires` are mandatory — missing
  fields fail the build, expired entries are ignored (findings gate again).
* Offline data: semgrep rules are baked into agent-security; trivy DBs come
  through the platform registry (Nexus ghcr-proxy); Dependency-Check reads the
  host-maintained NVD mirror (`/owasp-dc`). Nothing reaches the internet.

## GitOps steps (Phase 8)

* `updateGitOps(service:, env:, digest:, imageName:)` — render-and-commit
  (D-26): clones the gitops repo (askpass auth), re-renders
  `applications/<slug>/base/manifests.yaml` with pinned helm (skip for
  `deploymentType: kustomize`), pins `IMAGE_DIGEST_<slug>` into the target
  overlay's `images:` transformer, pushes `main` with rebase-retry.
  Outputs `GITOPS_APP_<slug>` / `GITOPS_ENV_<slug>` for `deployApplication`.
* `deployApplication(service:, appName:, env:)` — `argocd app wait --sync
  --health` as `jenkins-cd` (RBAC: get/sync only); prints ArgoCD diagnostics
  on failure; sets `DEPLOY_ENVIRONMENT`. Connection via `ARGOCD_SERVER_URL` /
  `ARGOCD_OPTS` (secrets/argocd.env) + `argocd-auth-token` credential.
* `promoteDigest(service:, targetEnv:, sourceEnv:, digest:, wait:)` — the only
  path to qa/uat/prod: copies the pinned digest between overlays (or pins an
  explicit `digest:` — that is a rollback). Backs the seeded job
  `platform/gitops-promotion`.
* Shared mechanics live in `src/org/company/devsecops/GitOpsRepo.groovy`:
  askpass clone (token never on disk/URL), yq digest pinning that FAILS when
  the image entry is missing, placeholder-digest rejection on promotion
  sources, commit+push with rebase-retry. All three steps are fail-closed on
  `SET_IN_PHASE_8` credential placeholders.
