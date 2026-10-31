# Installation & Operations Guide

> Phase 1 (architecture) and Phase 2 (Docker Compose infrastructure) content is **final**.
> Phases 3–11 extend this document with per-component setup procedures.

---

## 0. Target topology

- **Control-plane host** — Linux + Docker Engine ≥ 27 + Compose v2 ≥ 2.32, sized per
  `architecture.md` §7.2 (lab: 16 vCPU / 48 GB / 500 GB SSD; production: 32 vCPU / 96–128 GB / 2 TB NVMe).
- **Deployment plane** — existing Kubernetes cluster (Option A) **or** K3s v1.35.x (Option B,
  reference default, decision D-01). Provisioned in Phase 8.

Nothing is installed on the host except Docker, Compose and the kernel parameters below —
every platform component runs in its own container.

## 1. Host prerequisites

### 1.1 Required software

```bash
docker version --format '{{.Server.Version}}'   # >= 27.x
docker compose version                          # >= v2.32
docker buildx version                           # present (Phase 3 image builds)
openssl version                                 # secrets + internal CA generation
envsubst --version                              # GNU gettext (renders Traefik dynamic config)
curl --version                                  # health probes
# Debian/Ubuntu:  sudo apt-get install -y openssl gettext-base curl
# RHEL/Fedora:    sudo dnf install -y openssl gettext curl
```

### 1.2 Kernel parameters

`scripts/bootstrap.sh` writes and applies `/etc/sysctl.d/99-devsecops.conf` automatically:

```ini
vm.max_map_count = 524288            # SonarQube embedded Elasticsearch — hard requirement
vm.swappiness = 1
fs.file-max = 1048576
fs.inotify.max_user_watches = 524288
net.core.somaxconn = 4096
net.ipv4.ip_forward = 1
user.max_user_namespaces = 15000     # rootless BuildKit + unprivileged agent containers
```

Managed hosts where sysctls are centrally configured: use `bootstrap.sh --skip-sysctl`
after applying the values yourself. Verify: `sysctl vm.max_map_count` → `524288`.

### 1.3 Storage & ports

```bash
sudo mkdir -p /opt/devsecops                 # project checkout (git clone target)
sudo mkdir -p /mnt/data/devsecops            # DATA_ROOT (dedicated disk/LV in production)
ss -tlnp | grep -E ':(80|443|2222)\b'        # must be EMPTY (configurable in .env)
```

### 1.4 DNS / client trust

Every client must resolve the platform subdomains of `${PLATFORM_DOMAIN}`
(`gitlab.`, `jenkins.`, `sonar.`, `nexus.`, `registry.`, `vault.`, `grafana.`,
`prometheus.`, `alertmanager.`) — internal DNS in production, `/etc/hosts` in lab.
For docker clients to trust the registry endpoint:

```bash
sudo mkdir -p /etc/docker/certs.d/registry.<PLATFORM_DOMAIN>
sudo cp reverse-proxy/certificates/ca.crt /etc/docker/certs.d/registry.<PLATFORM_DOMAIN>/ca.crt
# Browsers/CLIs: import reverse-proxy/certificates/ca.crt into the OS/user trust store
```

---

## 2. Installation (Phase 2 — final)

### 2.1 Configure

```bash
cd /opt/devsecops/devsecops-platform
cp .env.example .env && chmod 600 .env
$EDITOR .env        # at minimum: PLATFORM_DOMAIN, DATA_ROOT, sizing per host profile
```

`.env` holds **no secrets** — only domains, pinned versions, sizing and retention. Every
variable is documented inline in `.env.example`.

### 2.2 Bootstrap (exact commands)

```bash
./scripts/bootstrap.sh                        # core profile (GitLab, Jenkins, Sonar, Nexus, Vault, Traefik)
./scripts/bootstrap.sh --with-monitoring      # + Prometheus, Grafana, Loki, Alloy, Alertmanager, exporters
./scripts/bootstrap.sh --with-build           # + rootless BuildKit + docker-socket-proxy
./scripts/bootstrap.sh --with-backup          # + restic backup runner
./scripts/bootstrap.sh --all                  # everything
./scripts/bootstrap.sh --prod                 # base + docker-compose.prod.yml (always-restart, RO rootfs, prod limits)
./scripts/bootstrap.sh --dry-run              # validate + render configs, start nothing
```

`bootstrap.sh` is idempotent and performs, in order:
prerequisite checks → `.env` creation → sysctls → data directories with correct uids
(§6.3 of architecture.md) → secret generation (`secrets/*.env`, mode 0600, gitignored) →
internal CA + wildcard certificate → Traefik dynamic-config rendering → `validate.sh`
pre-flight → `docker compose pull` → `docker compose up -d`.

### 2.3 Expected successful output

```
[INFO]  Applying kernel parameters (/etc/sysctl.d/99-devsecops.conf)
[ OK ]  vm.max_map_count=524288
[ OK ]  Data directories ready
[INFO] generated secret: sonar-db.env      (… one line per new secret)
[ OK ]  Certificates written to …/reverse-proxy/certificates
[ OK ]  Rendered Traefik dynamic config → …/dynamic/dynamic.yml
[ OK ]  no 'latest'/untagged images in compose files
[ OK ]  docker compose config: all profiles parse successfully
VALIDATION PASSED (0 warning(s))
[INFO] Pulling images (pinned versions only)…
[INFO] Starting platform…
 ✔ Container devsecops-platform-traefik-1        Started
 ✔ Container devsecops-platform-vault-1          Started
 … (17 services with --all)
Platform containers started. First start takes 5–10 minutes
```

First-boot durations (lab host): GitLab ~4–6 min (omnibus reconfigure), SonarQube ~2–4 min
(DB migration), Nexus ~2–3 min, Jenkins wizard-ready ~1 min.

### 2.4 One-time initializations (printed by bootstrap, do not skip)

1. **Vault** (never dev-mode, D-09):
   ```bash
   docker compose -f docker-compose.yml exec vault vault operator init -key-shares=5 -key-threshold=3
   # → store 5 unseal keys + initial root token OFF-HOST in sealed envelopes
   docker compose -f docker-compose.yml exec vault vault operator unseal    # ×3, different keys
   docker compose -f docker-compose.yml exec vault vault login              # root token
   docker compose -f docker-compose.yml exec vault vault audit enable file file_path=/vault/file/audit.log
   ```
   Jenkins AppRole, secret paths and rotation policies: Phase 11 (`vault/policies/`).
2. **GitLab** — `https://gitlab.<domain>`, user `root`, password in `secrets/gitlab.env`.
   Groups/projects/webhooks/branch protection: Phase 4.
3. **Jenkins** — `https://jenkins.<domain>` setup wizard (replaced by JCasC in Phase 3;
   admin credential already generated in `secrets/jenkins.env`).
4. **SonarQube** — `https://sonar.<domain>`, `admin` + forced password change on first login.
   Quality profiles/gates: Phase 5.
5. **Nexus** — `https://nexus.<domain>`, `admin` + initial password:
   `sudo cat ${DATA_ROOT}/nexus-data/admin.password`. **Repositories are NOT auto-created** —
   Phase 5 provisions docker/maven/npm/pypi/nuget/raw repos, cleanup policies and roles via
   `nexus/scripts/` REST automation.
6. **Grafana** — `https://grafana.<domain>`, credentials in `secrets/grafana.env`.
   Datasources (Prometheus/Loki/Alertmanager) are pre-provisioned; dashboards land in Phase 10.

### 2.5 Validation commands

```bash
./scripts/validate.sh                 # static pre-flight (any time; exit 0 = pass)
./scripts/health-check.sh             # live endpoint matrix through Traefik
./scripts/health-check.sh --wait      # poll until healthy (first boot), 10-min deadline
docker compose -f docker-compose.yml --profile all ps      # container health column
```

Expected `health-check.sh` output (steady state, after §2.4):

```
== endpoint health (via Traefik) ==
gitlab                       UP      (HTTP 200, matched "GitLab OK")
jenkins                      UP      (HTTP 200)
sonarqube                    UP      (HTTP 200, matched ""status":"UP"")
nexus                        UP      (HTTP 200)
grafana                      UP      (HTTP 200, matched ""database":"ok"")
vault                        UP (initialized, unsealed)
prometheus                   UP      (HTTP 200)
alertmanager                 UP      (HTTP 200)
registry (docker /v2/)       REACHABLE (HTTP 401 — until Phase 5 creates docker-group connector)
CORE SERVICES HEALTHY
```

`registry` returning 404/502 before Phase 5 is **expected** (the Nexus docker-group
connector does not exist yet); `jenkins` job in Prometheus showing DOWN before Phase 3 is
expected (Prometheus plugin not yet installed) — both are annotated in the configs.

---

## 3. Day-2 operations

```bash
# Compose invocations always pass -f explicitly so docker-compose.override.yml
# (developer direct-ports) is never applied by accident:
DC="docker compose -f docker-compose.yml"

$DC --profile core --profile monitoring ps
$DC --profile core stop|start|restart
$DC logs -f --tail=200 jenkins
$DC exec vault vault status
$DC --profile all down                    # stop everything, keep data
./scripts/cleanup.sh                      # down + remove networks
./scripts/cleanup.sh --images             # … also remove pinned images
./scripts/cleanup.sh --purge              # DESTRUCTIVE: deletes DATA_ROOT contents,
                                          # secrets and TLS material (type 'yes')
```

Local development without Traefik/TLS: plain `docker compose up -d` in the project root
auto-merges `docker-compose.override.yml` and binds service ports to **127.0.0.1 only**
(Jenkins 8080/50000, Sonar 9000, Nexus 8081/8083/8085, Vault 8200, Grafana 3000,
Prometheus 9090, Alertmanager 9093, Loki 3100, Traefik dashboard 8082).

Production rollout: `./scripts/bootstrap.sh --prod --all`.

---

## 4. Failure scenarios & troubleshooting (Phase 2)

| Symptom | Diagnosis | Fix |
|---------|-----------|-----|
| `sonarqube` restart-loops, log shows `max virtual memory areas vm.max_map_count [65530] is too low` | sysctl not applied | `sudo sysctl -w vm.max_map_count=524288` + persist via bootstrap; `$DC restart sonarqube` |
| `nexus` exits with permission errors on `/nexus-data` | wrong uid on bind mount | `sudo chown -R 200:200 ${DATA_ROOT}/nexus-data` |
| `sonarqube-db` fails `chown: /var/lib/postgresql/data: operation not permitted` | wrong uid | `sudo chown -R 999:999 ${DATA_ROOT}/sonarqube-db` |
| `gitlab` unhealthy > 10 min | omnibus reconfigure still running or OOM | `$DC logs gitlab | tail -50`; raise `GITLAB_MEM_LIMIT` (8g min); check `docker stats` |
| `traefik` up but all routes 404 | dynamic config not rendered / wrong domain | `ls reverse-proxy/configuration/dynamic/dynamic.yml`; re-run `bootstrap.sh`; verify `Host()` rules vs the URL you typed |
| browser: `NET::ERR_CERT_AUTHORITY_INVALID` | internal CA not trusted on client | import `reverse-proxy/certificates/ca.crt` (§1.4) |
| `curl https://jenkins.<domain>` works, `http://` hangs | port 80 redirect | expected — web entrypoint redirects to websecure |
| `vault` shows SEALED after host reboot | by design (no auto-unseal in lab) | `vault operator unseal` ×3 (D-09; transit auto-unseal is a Phase 11 production option) |
| port 80/443/2222 already bound | conflicting host service | `ss -tlnp \| grep -E ':(80\|443\|2222)'`; stop offender or change `HTTP_PORT/HTTPS_PORT/GITLAB_SSH_PORT` in `.env` |
| `docker compose config` errors on `env_file ./secrets/…` | bootstrap not run (secrets missing) | `./scripts/bootstrap.sh` generates them |
| Jenkins wizard asks for initial password | first boot | `docker compose -f docker-compose.yml exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword` — or use `secrets/jenkins.env` after Phase 3 JCasC |
| `alloy` logs `connection refused` to socket-proxy | `build` profile not running | `bootstrap.sh --with-build` (Alloy retries and recovers automatically) |

General:

```bash
$DC --profile all ps -a                       # exit codes / health
$DC logs --tail=200 <service>                 # or query Loki in Grafana once Phase 10 dashboards land
docker stats --no-stream                      # live resource use vs limits (architecture §7.1)
docker network inspect devsecops-cicd         # membership vs architecture §4.1
./scripts/validate.sh                         # config-level regressions
```

## 5. Security considerations (Phase 2)

- Only Traefik publishes 80/443 (+ GitLab SSH 2222, the documented exception).
- `secrets/` is 0700, files 0600, gitignored; gitleaks pre-commit enforcement arrives Phase 7.
- Vault and admin routes are IP-allow-listed at the proxy (`ADMIN_IP_ALLOWLIST`);
  Prometheus/Alertmanager routes require basic auth (credentials in `secrets/monitoring.env`).
- `docker-socket-proxy` exposes an allow-list (`CONTAINERS/IMAGES/NETWORKS/VOLUMES/INFO/VERSION/PING/POST`);
  `AUTH/EXEC/SWARM/SYSTEM/EVENTS/SESSION/BUILDER/GRPC/SECRETS` are explicitly denied.
- BuildKit runs rootless; `no-new-privileges` on every service that supports it;
  read-only rootfs enforced in `docker-compose.prod.yml` where images allow.
- Rotate the bootstrap-generated passwords into Vault-managed credentials during Phase 11;
  until then `secrets/*.env` is the single location — never copy values into Git or tickets.

## 6. Backup & recovery considerations (Phase 2 baseline)

- The `backup` profile runs `scripts/backup-runner.sh`: restic file-level backup of
  `DATA_ROOT` every `BACKUP_INTERVAL_HOURS` (default 24 h), retention 7 daily / 4 weekly /
  6 monthly, 5 % sample verification each cycle. Repository: `${DATA_ROOT}/backups/repo` by
  default — **set `RESTIC_REPOSITORY_LOCAL` to an off-host target (S3/REST/SSH) in production.**
- Known limitation until Phase 11 (documented, not hidden): file-level copies of *running*
  databases are not transaction-consistent. Phase 11 adds component-native dumps
  (`gitlab-backup create`, `pg_dump`, Nexus backup task, `vault operator raft snapshot`,
  Prometheus snapshot API) staged into `DATA_ROOT/backups/staging` before each restic cycle.
- Restore drill (Phase 11 `scripts/restore.sh`); until then:
  `restic -r <repo> snapshots`, `restic restore <snapshot> --target /tmp/restore`.
- RPO 24 h / RTO per `architecture.md` §12.

## 7. Phase 2 completion checklist

- [x] `docker-compose.yml` — 17 services, 7 networks, profiles `core/monitoring/build/backup/all`
- [x] All images pinned to versions verified 2026-10-30 (no `latest` — enforced by `validate.sh`)
- [x] Persistent storage: uid-correct bind directories per architecture §6.3
- [x] Healthchecks on every long-running service; `depends_on: service_healthy` chains
- [x] Restart policies, memory/CPU limits + reservations, json-file log rotation (50 MB × 3; 100 MB × 5 in prod)
- [x] Traefik: static + template-rendered dynamic config, wildcard TLS from internal CA,
      IP-allowlist on Vault, basic-auth on monitoring routes, SNI router for the Docker registry
- [x] `docker-compose.override.yml` (127.0.0.1-only dev ports) and `docker-compose.prod.yml`
      (restart:always, RO rootfs, prod sizing, wizard disabled)
- [x] `.env.example` fully documented, secret-free
- [x] `scripts/bootstrap.sh` / `validate.sh` / `health-check.sh` / `cleanup.sh` + `lib/common.sh`
- [x] Baseline Prometheus rules + Alertmanager routing + Loki 14-day retention + Alloy log pipeline via socket-proxy
- [x] Vault: raft storage, no dev-mode, unauthenticated metrics for Prometheus, documented init/unseal ceremony
- [x] Baseline restic backup service (`--with-backup`)
- [x] Template rendering pipeline tested (envsubst → YAML validation)
- [ ] Live first-boot executed on target host (run `./scripts/bootstrap.sh --all` + `./scripts/health-check.sh --wait`)

---

## 8. Jenkins layer (Phase 3 — final)

### 8.1 What Phase 3 adds

| Artifact | Purpose |
|----------|---------|
| `jenkins/Dockerfile` | Custom controller image: `jenkins/jenkins:2.568.3-lts-jdk21` + 29 pinned plugins (baked, immutable); JCasC/init mounted from repo at runtime |
| `jenkins/plugins.txt` | Plugin pins verified 2026-10-30 against plugins.jenkins.io; every `requiredCore` ≤ 2.568.3 |
| `jenkins/casc/*.yaml` | 6-file JCasC: core (0 executors), security (local realm + §17 role matrix, DSL sandbox policy), credentials (fail-closed placeholders), Docker cloud (JNLP connector via socket-proxy), warm nodes, integrations (GitLab/Sonar/library/Prometheus/SMTP), seed folders |
| `jenkins/init.groovy.d/` | CLI subsystem disabled; startup banner + drift warning |
| `jenkins/agents/*/Dockerfile` | 7 agent images (general, python, security warm; java-maven, java-gradle, dotnet, nodejs dynamic) — all tool URLs pinned & HTTP-200-verified |
| `jenkins/agents/common/fetch-secret-connect.sh` | Inbound-agent secret bootstrap (admin creds from `secrets/jenkins.env`, never baked) |
| `jenkins/shared-library/` | `devsecops-shared-library`: microservicePipeline orchestrator, detectProject engine, validateProject, notifyResult + 4 src classes, platform-config, default security policy, examples |
| `scripts/build-images.sh` | Builds controller + agent images |

### 8.2 Exact commands

```bash
# .env already sets: JENKINS_IMAGE_OVERRIDE=devsecops/jenkins-controller,
#                    JENKINS_VERSION=2.568.3-lts-jdk21, AGENT_IMAGE_TAG=1.0.0
./scripts/build-images.sh                       # or let bootstrap.sh do it
./scripts/bootstrap.sh --with-build --with-agents --with-monitoring
# bootstrap detects JENKINS_IMAGE_OVERRIDE / agents profile and runs
# build-images.sh automatically (skip with --skip-build)
```

### 8.3 Validation (expected results)

```bash
./scripts/health-check.sh --wait
# jenkins endpoint: UP (HTTP 200)

# 1. JCasC applied without errors:
curl -sk -u admin:$(grep ^JENKINS_ADMIN_PASSWORD= secrets/jenkins.env | cut -d= -f2) \
  --resolve jenkins.devsecops.internal:443:127.0.0.1 \
  https://jenkins.devsecops.internal/configuration-as-code/check | head
# UI: /configuration-as-code → no red "failed" entries;
#     /manage/configuration-as-code/reference renders (schema self-check)

# 2. Controller has ZERO executors:
curl -sk -u admin:<pass> https://jenkins.devsecops.internal/computer/api/json?tree=displayName,offline \
  | jq '.computer[] | {displayName, offline}'
# → 3 warm nodes (agent-general, agent-python, agent-security) come ONLINE
#   within ~3 min; "Built-In Node" has 0 executors

# 3. Docker cloud visible: /manage/cloud/ → docker-agents with 4 templates
#    (templates only provision containers when a matching label is requested —
#     that happens once Phase 6 flips build stage flags)

# 4. Jenkins metrics job goes UP in Prometheus (~1 scrape interval):
curl -sk -u monitoring:<pass-from-secrets/monitoring.env> \
  https://prometheus.devsecops.internal/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.job=="jenkins") | .health'
# → "up"
```

### 8.4 Credentials & RBAC

- `secrets/jenkins.env` now contains the admin + 6 role-account passwords
  (platform-admin, devops-admin, developer, security-engineer,
  release-manager, app-owner) — the §17 role matrix is wired in
  `jenkins/casc/10-security.yaml`. Log in once per role and verify the
  permission boundary (developer must NOT see /manage; security-engineer
  cannot configure jobs).
- All `SET_IN_PHASE_*` credential placeholders are FAIL-CLOSED: any stage
  using them fails with a clear message until Phases 4–11 provision real
  values (GitLab PAT → Phase 4, Sonar/Nexus → Phase 5, cosign/GitOps/ArgoCD →
  Phase 7/8, Vault AppRole → Phase 11).
- Production sites: swap `securityRealm.local` for LDAP/OIDC in
  `10-security.yaml`; the matrix maps principals, so only entry types change
  (`user:` → `group:`).

### 8.5 Phase 3 failure scenarios & troubleshooting

| Symptom | Diagnosis | Fix |
|---------|-----------|-----|
| Jenkins UI shows "Configuration as Code failed" banner | YAML schema mismatch after a plugin update | `/manage/configuration-as-code/reference` → compare with `jenkins/casc/`; plugin versions are pinned so this only happens after deliberate upgrades |
| Warm agent containers restart-loop, log `waiting for node 'agent-X' to be registered` | Controller not up yet or JCasC nodes section failed | check controller health first; `docker compose logs jenkins \| grep -i casc` |
| Agent log: `could not extract agent secret` | Node exists but is not inbound (JNLP) type | ensure `40-nodes.yaml` applied (`launcher.jnlp`); do not recreate nodes via UI |
| Agent log: `401` from controller | secrets/jenkins.env out of sync with the realm (e.g. env regenerated after first boot) | passwords are stored hashed in jenkins-home; either reuse the original secrets file or reset via `java -jar jenkins-cli` alternative: temporarily re-run the wizard, or restore jenkins-home from backup |
| Docker cloud shows "Cannot connect" | `build` profile not running | `bootstrap.sh --with-build` (socket-proxy + buildkitd) |
| Dynamic agent container starts but never connects | template `network` must be `devsecops-agents` and image entrypoint intact | verify `docker network inspect devsecops-agents`; check template in `/manage/cloud/docker-agents/` |
| `build-images.sh` fails pulling `jenkins/inbound-agent:3395…` | tag typo in `.env` INBOUND_AGENT_VERSION | restore value from `.env.example` (verified 2026-10-30) |
| Plugin install fails during image build | network/registry hiccup or checksum mismatch | re-run build (layers are cached); pins are from the official update center — do not "fix" by unpining |

### 8.6 Phase 3 security considerations

- Controller: **0 executors**, no Docker socket, no Docker CLI; plugin set
  pinned at build time (supply-chain reproducible); CLI subsystem disabled
  (`init.groovy.d/01-hardening.groovy`); only JNLP4 agent protocol enabled;
  `no-new-privileges` + non-root uid 1000.
- Agents: inbound-only on an **internal** network (D-16) — no direct internet;
  dependencies exclusively via Nexus (from Phase 5); scanner DB downloads only
  on `agent-security` via `security-network`.
- Socket-proxy allow-list unchanged (`EXEC` stays **denied** — dynamic agents
  use the JNLP connector, verified against docker-plugin sources).
- Job DSL sandbox is disabled ONLY for JCasC-embedded seed scripts (trusted
  authorship); application pipeline scripts remain sandboxed.

### 8.7 Phase 3 completion checklist

- [x] Custom controller Dockerfile + pinned plugins.txt (29 plugins, all requiredCore ≤ 2.568.3, verified via official APIs)
- [x] JCasC: 6 modular files — core/security/credentials/clouds/nodes/integrations/seed jobs
- [x] Role matrix implementing §17 (6 roles) with least-privilege permission sets
- [x] Fail-closed credential placeholders mapped to provisioning phases
- [x] Docker cloud via allow-listed socket-proxy, JNLP connector (no EXEC), internal agents network
- [x] 3 warm agents (compose services, auto-connecting) + 4 dynamic templates
- [x] 7 agent Dockerfiles, every tool version pinned & download URL verified (HTTP 200)
- [x] Shared library foundation: orchestrator + discovery engine + validation + notifications + policy engine classes
- [x] Stage-flag incremental-enablement contract (platform-config.yaml)
- [x] build-images.sh + bootstrap integration (--with-agents, --skip-build, --ignore-pull-failures)
- [ ] Live first-boot on target host (run §8.2 + §8.3)

---

## 9. GitLab layer (Phase 4 — final)

### 9.1 What Phase 4 adds

| Artifact | Purpose |
|----------|---------|
| `gitlab/scripts/lib/gitlab-api.sh` | API helper — every call runs **inside** the gitlab container against `http://localhost/api/v4` (no host TLS/DNS dependency, GitLab never exposes its API port) |
| `gitlab/scripts/10-create-root-token.sh` | Bootstraps the admin PAT (`platform-bootstrap`) via `gitlab-rails runner`; validates stored token before recreating |
| `gitlab/scripts/20-users-groups.sh` | Groups `platform`/`teams`; service users `jenkins-ci` (least-privilege PATs: `ci-api` [api, read_repository], `gitops-write` [write_repository]) and `argocd`; webhook shared secret |
| `gitlab/scripts/30-projects.sh` | Projects `platform/devsecops-shared-library` + `platform/gitops-repository`; merge methods; protected branches/tags; memberships; merge-approvals attempt with graceful CE degradation |
| `gitlab/scripts/40-seed-repositories.sh` | Seeds the library repo from `jenkins/shared-library/` and the §12 GitOps skeleton (+ CODEOWNERS) via omnibus-embedded git — idempotent |
| `gitlab/scripts/add-webhook.sh` / `remove-webhook.sh` | Per-project Jenkins webhook tooling (project webhooks — group webhooks are Premium) |
| `gitlab/scripts/run-all.sh` | Orchestrates 10→40 + webhook + GitLab→Jenkins connectivity check |
| compose | `initial_root_password` from secrets; `allow_local_requests_from_web_hooks_and_services=true` (D-18); backup keep-time 14 d; internal CA installed into `/etc/gitlab/trusted-certs/` by bootstrap |

### 9.2 Exact commands

```bash
# Prerequisite: core profile running and GitLab healthy (first boot 5–10 min)
./scripts/health-check.sh                     # gitlab endpoint: UP (GitLab OK)

./gitlab/scripts/run-all.sh                   # full Phase 4 provisioning (idempotent)

# Refresh Jenkins so JCasC credentials pick up the new GitLab PATs:
docker compose -f docker-compose.yml --profile core up -d jenkins
# (compose recreates the container because secrets/gitlab-jenkins.env changed)
```

### 9.3 Expected successful output

```
== Phase 4: GitLab provisioning ==
[ OK ]  stored GITLAB_ROOT_TOKEN is valid (GitLab 19.5.1)   ← or "root PAT created"
[ OK ]  group 'platform' exists / created …
[INFO] PAT 'ci-api' created → GITLAB_API_TOKEN …
[ OK ]  project platform/devsecops-shared-library …
[ OK ]  protected branch 'main' (push=0, merge=40) …
[ OK ]  protected tag 'v*' …
[ OK ]  member uid=… → project … (access=40)
[ OK ]  platform/devsecops-shared-library: seeded (branch main)
[ OK ]  platform/gitops-repository: seeded (branch main)
[ OK ]  webhook → http://jenkins:8080/project/platform/devsecops-shared-library registered
[ OK ]  GitLab→Jenkins internal reachability verified (HTTP 200)
Phase 4 complete.
```

On CE you will ALSO see the documented warning:
`merge approvals API returned HTTP 403 … PREMIUM feature` — expected (D-19).

### 9.4 Validation commands

```bash
source secrets/gitlab.env secrets/gitlab-jenkins.env
GL="docker compose -f docker-compose.yml exec -T gitlab curl -sS -H PRIVATE-TOKEN:$GITLAB_ROOT_TOKEN http://localhost/api/v4"

$GL/groups/platform/projects | jq -r '.[].path_with_namespace'
# → platform/devsecops-shared-library  platform/gitops-repository

$GL/projects/platform%2Fdevsecops-shared-library/protected_branches | jq -r '.[].name'
# → main
$GL/projects/platform%2Fgitops-repository/repository/tree | jq -r '.[].name'
# → applications  clusters  CODEOWNERS  helm-charts  README.md

# Jenkins credential is live after the recreate:
curl -sk -u admin:$(grep ^JENKINS_ADMIN_PASSWORD= secrets/jenkins.env | cut -d= -f2) \
  https://jenkins.$(grep ^PLATFORM_DOMAIN= .env | cut -d= -f2)/credentials/store/system/domain/_/ | grep -c gitlab
```

### 9.5 Failure scenarios & troubleshooting

| Symptom | Diagnosis | Fix |
|---------|-----------|-----|
| `10-` fails: rails runner hangs/timeouts | GitLab still reconfiguring | wait for `health-check.sh` gitlab UP; re-run (idempotent) |
| `20-`: PAT creation returns 403 | root token expired/revoked | re-run `10-create-root-token.sh` (detects invalid token, regenerates) |
| Webhook test delivery returns 404 | matching Jenkins job not created yet (Phase 6) | expected until the multibranch/seed job exists — GitLab retries on next event |
| Webhook delivery fails "Url is blocked: Requests to the local network are not allowed" | omnibus flag not applied | verify `allow_local_requests_from_web_hooks_and_services` in GITLAB_OMNIBUS_CONFIG; `docker compose up -d gitlab` then `docker compose exec gitlab gitlab-ctl reconfigure` |
| `40-` push fails 401 | root token rotated mid-run | re-run `10-`, then `40-` |
| Library repo shows stale seed | `40-` skips when `main` exists | delete project (or push a revert commit) and re-run `run-all.sh` |
| Jenkins still uses SET_IN_PHASE_4 credential | container not recreated after token write | `docker compose -f docker-compose.yml --profile core up -d jenkins` (forces recreate on env_file change) |

### 9.6 CE vs Premium (documented limitation, decision D-19)

| Capability | CE (this platform) | Premium |
|------------|--------------------|---------|
| Protected branches/tags | ✅ enforced | ✅ |
| "Pipelines must succeed" (commit-status gate) | ✅ enforced | ✅ |
| MR-only flow to protected branches | ✅ enforced | ✅ |
| CODEOWNERS **required** approval | file seeded, not enforced | ✅ auto-enforced |
| Merge approval rules | attempted; 403 → warned | ✅ |
| Push rules | not available | ✅ |
| Group-level webhooks | per-project script instead | ✅ |

All automation is written to activate Premium behaviors automatically once a
license is applied — no script changes required.

### 9.7 Security & backup notes

- The root PAT and user PATs live only in `secrets/*.env` (0600, gitignored);
  Phase 11 migrates them to Vault dynamic tokens with rotation.
- `jenkins-ci` has NO access to `platform` group settings and CANNOT push to
  the library's protected `main` (Reporter there) — MR-only.
- Webhook secret is shared between GitLab hooks and the Jenkins GitLab
  connection (Phase 6); rotate by re-running `add-webhook.sh` after updating
  `GITLAB_WEBHOOK_TOKEN`.
- Backups: `docker compose exec gitlab gitlab-backup create` + tar of
  `${DATA_ROOT}/gitlab/config` (contains gitlab-secrets.json, trusted-certs) —
  both inside restic scope; full procedure in Phase 11.

### 9.8 Phase 4 completion checklist

- [x] API automation library (in-container, no exposed API port)
- [x] Root PAT bootstrap via rails runner with validity detection
- [x] Groups platform/teams + service users jenkins-ci/argocd
- [x] Least-privilege PATs (ci-api / gitops-write) wired into Jenkins JCasC credentials
- [x] Projects with merge methods, protected branches (main) and tags (v*, rel-*)
- [x] Memberships implementing §17 least privilege
- [x] Merge approvals attempted + documented CE degradation (D-19)
- [x] Repositories seeded: shared library (from jenkins/shared-library) + GitOps skeleton with CODEOWNERS
- [x] Webhook tooling + GitLab→Jenkins internal connectivity check (D-18)
- [x] Omnibus hardening: deterministic root password, local-request policy, backup keep-time, internal CA trust
- [ ] Live run on target host (`./gitlab/scripts/run-all.sh` + §9.4 validations)

---

## 10. SonarQube & Nexus layer (Phase 5 — final)

### 10.1 What Phase 5 adds

| Artifact | Purpose |
|----------|---------|
| `sonarqube/scripts/lib/sonar-api.sh` | API helper — calls run **inside** the sonarqube container against `http://localhost:9000/api` (port never exposed) |
| `sonarqube/scripts/10-admin-bootstrap.sh` | Rotates factory `admin/admin` password; hardening (`sonar.forceAuthentication=true`, serverBaseURL, provisioning admin-only); service user `jenkins` with **Execute Analysis only**; analysis token → `secrets/sonar-jenkins.env`; best-effort global webhook → `http://jenkins:8080/sonarqube-webhook/` |
| `sonarqube/scripts/20-quality-gates.sh` | `platform-default` (gate for ALL new projects) + `platform-strict`; conditions synced declaratively |
| `nexus/scripts/lib/nexus-api.sh` | API helper (in-container, `http://localhost:8081/service/rest/v1`) |
| `nexus/scripts/10-admin-bootstrap.sh` | Consumes `/nexus-data/admin.password`, rotates admin → `secrets/nexus.env`, deletes bootstrap file, **disables anonymous access** |
| `nexus/scripts/20-cleanup-policies.sh` | 6 retention policies (proxies only — hosted digests/releases are never auto-deleted, D-21) |
| `nexus/scripts/30-repositories.sh` | 5 proxies + 7 hosted + 5 groups; `docker-group` connector on **:8085** = the Traefik `registry.<domain>` TCP router target |
| `nexus/scripts/40-users-roles.sh` | Role `jenkins-deploy` (read-all, publish-hosted, **no delete/admin**) + user `jenkins-ci` → `secrets/nexus-jenkins.env`; credentials validated end-to-end |
| `*/scripts/run-all.sh` | Per-tool orchestration + registry probe through Traefik |
| `jenkins/shared-library/vars/runSonarAnalysis.groovy` | Quality-Gate stage implementation: language-aware scanners, `sonar.qualitygate.wait=true` (D-20), CE branch isolation via project keys |
| compose | jenkins `env_file` += `sonar-jenkins.env`, `nexus-jenkins.env` |
| bootstrap | placeholder secret files for both (contract exists from day one) |

### 10.2 Quality gates (platform-wide)

| Condition (NEW code) | platform-default | platform-strict |
|----------------------|------------------|-----------------|
| Coverage | ≥ 80 % | ≥ 90 % |
| Duplicated lines | ≤ 3 % | ≤ 1 % |
| Maintainability / Reliability / Security / Security-review rating | A | A |
| Newly accepted (won't-fix) issues | — | 0 |

`platform-default` is set as the instance default gate. A service opts into
strict via `sonar.qualitygate` in its project settings (or `devsecops.yaml`
`extra.sonarProjectKey` conventions documented in the library README).

### 10.3 Exact commands

```bash
./scripts/health-check.sh                  # sonarqube UP + nexus 200 expected
./sonarqube/scripts/run-all.sh
./nexus/scripts/run-all.sh

# ONE-TIME (Nexus exposes no REST API for scheduled tasks):
#   Nexus UI (https://nexus.<domain>) → System → Tasks → Create task:
#     1) "Admin - Cleanup service"                    — cron daily 02:00
#     2) "Remove snapshots from Maven repository"     — repo maven-snapshots,
#        daily 03:00, keep 3 versions, remove if released
#   (admin login: secrets/nexus.env)

# Activate Jenkins credentials:
docker compose -f docker-compose.yml --profile core up -d jenkins
```

### 10.4 Expected successful output

```
== Phase 5: SonarQube provisioning ==
[ OK ]  SonarQube is UP
[ OK ]  admin password set → secrets/sonar.env (SONAR_ADMIN_PASSWORD)
[ OK ]  sonar.forceAuthentication=true (anonymous access disabled)
[ OK ]  service user 'jenkins' created …
[ OK ]  analysis token 'platform-jenkins' created → secrets/sonar-jenkins.env
[ OK ]  global webhook → http://jenkins:8080/sonarqube-webhook/ created
[ OK ]  quality gate 'platform-default' conditions synced (6 conditions)
[ OK ]  'platform-default' is the default gate for new projects

== Phase 5: Nexus Repository provisioning ==
[ OK ]  Nexus is writable
[ OK ]  admin password rotated → secrets/nexus.env; bootstrap file removed
[ OK ]  anonymous access disabled …
[ OK ]  cleanup policy 'cleanup-maven2' created … (×6)
[ OK ]  repository 'maven-central' created (maven/proxy) … (×17)
[ OK ]  role 'jenkins-deploy' created
[ OK ]  user 'jenkins-ci' created
[ OK ]  jenkins-ci credentials validated (read maven-central → HTTP 200)
[ OK ]  docker registry reachable via Traefik: https://registry.<domain>/v2/ (HTTP 401)
```

If your edition lacks webhook support, script 10 logs the documented WARN and
continues — gate enforcement stays scanner-side (D-20), nothing breaks.

### 10.5 Validation commands

```bash
source secrets/sonar.env secrets/sonar-jenkins.env secrets/nexus.env secrets/nexus-jenkins.env

# SonarQube: gates + token + settings
docker compose -f docker-compose.yml exec -T sonarqube \
  curl -sS -u admin:$SONAR_ADMIN_PASSWORD \
  "http://localhost:9000/api/qualitygates/list" | jq -r '.qualitygates[] | select(.isDefault==true) | .name'
# → platform-default
docker compose -f docker-compose.yml exec -T sonarqube \
  curl -sS -u jenkins:$SONARQUBE_TOKEN http://localhost:9000/api/authentication/validate
# → {"valid":true,"login":"jenkins"}

# Nexus: repos + registry endpoint
docker compose -f docker-compose.yml exec -T nexus \
  curl -sS -u admin:$NEXUS_ADMIN_PASSWORD http://localhost:8081/service/rest/v1/repositories \
  | jq -r '.[].name' | sort | tr '\n' ' '
# → docker-group docker-hosted docker-proxy maven-central maven-public maven-releases
#   maven-snapshots npm-hosted npm-proxy npm-public nuget-hosted nuget-proxy
#   nuget-public pypi-hosted pypi-proxy pypi-public raw-hosted
curl -sk -u $NEXUS_DEPLOY_USER:$NEXUS_DEPLOY_PASSWORD \
  --resolve registry.$(grep ^PLATFORM_DOMAIN= .env | cut -d= -f2):443:127.0.0.1 \
  https://registry.$(grep ^PLATFORM_DOMAIN= .env | cut -d= -f2)/v2/_catalog
# → {"repositories":[]}   (auth works, registry empty until Phase 6 pushes)

# Jenkins side after recreate:
curl -sk -u admin:$(grep ^JENKINS_ADMIN_PASSWORD= secrets/jenkins.env | cut -d= -f2) \
  "https://jenkins.$(grep ^PLATFORM_DOMAIN= .env | cut -d= -f2)/manage/descriptorByName/hudson.plugins.sonar.SonarInstallation/configure" -o /dev/null -w '%{http_code}\n'
# → 200 (SonarQube installation present; token live from env)
```

### 10.6 Failure scenarios & troubleshooting

| Symptom | Diagnosis | Fix |
|---------|-----------|-----|
| Sonar script 10 dies "not UP within 20 min" | ES bootstrap checks / memory | `docker compose logs sonarqube`; ensure `vm.max_map_count=262144` (bootstrap §1) and SONARQUBE_MEM_LIMIT ≥ 6 g |
| `users/create` fails 400 "email mandatory" | instance configured to require email | re-run after `POST /api/settings/set key=sonar.users.emailMandatory value=false`, or create user in UI |
| Webhook creation HTTP 403 | edition/tier without webhooks | EXPECTED fallback (D-20) — scanner-side wait enforces gates; no action |
| Gate always passes despite bad code | scanner missing `sonar.qualitygate.wait` | use the library step (sets it); raw `mvn sonar:sonar` calls must add it manually |
| Nexus 10 dies "neither stored nor bootstrap password" | `admin.password` deleted + password lost | restore from backup (Phase 11) or documented DB reset — script prints the exact recovery note |
| Registry probe HTTP 502/000 | docker-group connector port mismatch | confirm `NEXUS_DOCKER_GROUP_PORT` (default 8085) equals dynamic.yml Traefik TCP service `nexus:8085`; Nexus UI → Repositories → docker-group |
| Agent pushes fail 401 | jenkins-ci credential stale | re-run `nexus/scripts/40-users-roles.sh` (rotates placeholder), then recreate jenkins |
| Cleanup never deletes anything | scheduled task missing | §10.3 one-time UI task "Admin - Cleanup service" (REST cannot create tasks) |

### 10.7 Phase 5 completion checklist

- [x] SonarQube: admin rotation, forceAuthentication, serverBaseURL
- [x] SonarQube: least-privilege CI user (Execute Analysis only) + token → JCasC credential live
- [x] Quality gates platform-default/strict, default-gate assignment, declarative condition sync
- [x] Global webhook best-effort + documented scanner-side fallback (D-20)
- [x] Nexus: admin rotation from bootstrap file, anonymous disabled
- [x] Nexus: 17 repositories (5 proxy, 7 hosted, 5 group) + 6 cleanup policies
- [x] docker-group connector :8085 aligned with Traefik registry router (health-check 401 expected)
- [x] jenkins-deploy role (read-all/publish-hosted/no-delete) + jenkins-ci user, credentials validated
- [x] `runSonarAnalysis` shared-library step + `quality` stage flag flipped ON
- [x] sonar-scanner CLI added to agent-general (fallback analyses)
- [ ] One-time Nexus scheduled tasks (§10.3) + live run on target host

---

## 11. Multi-language CI (Phase 6 — final)

Phase 6 is mostly *library + JCasC* — no new host services. After applying it,
any GitLab project under `teams/<team>` with a standard Jenkinsfile gets a
full multibranch pipeline: build → unit → integration → quality gate →
package → image (BuildKit→Nexus registry) → publish, per language.

### 11.1 What Phase 6 adds

| Artifact | Purpose |
|----------|---------|
| `vars/buildApplication.groovy` | compile/dependency resolution per language (wrapper-aware, Nexus-only via RepoConfig) |
| `vars/runUnitTests.groovy` | tests + JUnit publication + coverage files for Sonar; failures block |
| `vars/runIntegrationTests.groovy` | convention-marker driven (failsafe / integrationTest task / Category=Integration / pytest marker / test:integration script); explicit skip when absent |
| `vars/packageApplication.groovy` | jar / publish-dir+nuget / wheel / tgz + `reports/package-<svc>.json` manifest |
| `vars/buildContainer.groovy` | BuildKit build+push, unique tag, digest capture (`env.IMAGE_DIGEST_<SVC>`), archived manifest |
| `vars/publishArtifact.groovy` | release-context publication policy → Nexus hosted repos (maven deploy + deploy-file fallback, gradle publish, twine/poetry, npm publish, nuget push) |
| `src/org/company/devsecops/RepoConfig.groovy` | per-build maven/gradle/npm/nuget/pip repository config (D-16, secrets env-expanded where possible) |
| `casc/60-jobs.yaml` | organization folders per team (example slugs `payments`, `orders`), hourly scan, tag/MR/branch discovery |
| `casc/50-unclassified.yaml` | `gitLabServers` entry (branch source server, webhook secret verification, hooks NOT auto-managed — D-22) |
| `casc/20-credentials.yaml` | `gitlabPersonalAccessToken` credential for the branch source |
| `microservicePipeline.groovy` | delivery stages → `agent none`; per-service node allocation + `source` stash/unstash; per-flag dispatch guards |
| `platform-config.yaml` | flags ON: build, unitTests, integrationTests, package, imageBuild, publish; new `nexus:` + `registry:` sections |
| `agents/general/Dockerfile` + `build-images.sh` | platform CA baked into agent-general (registry TLS trust, D-23) |

### 11.2 Exact commands (target host)

```bash
# 1) Rebuild agent-general (CA trust) — bootstrap.sh already generated the CA
./scripts/build-images.sh --agent general

# 2) Start BuildKit (image builds need the 'build' profile)
docker compose -f docker-compose.yml --profile core --profile build up -d buildkitd

# 3) Recreate Jenkins: new JCasC (servers, credentials, seed jobs) + library is
#    pulled from GitLab at runtime — seed the updated library first:
cd jenkins/shared-library && git add -A && git commit -m "phase-6" && git push   # if you track the library in Git
cd ../..
docker compose -f docker-compose.yml --profile core up -d jenkins

# 4) Onboard the example teams (or edit TEAMS in casc/60-jobs.yaml first):
#    - GitLab: create groups teams/payments, teams/orders + a project with the
#      standard Jenkinsfile (copy jenkins/shared-library/examples/Jenkinsfile)
#    - instant triggers:
./gitlab/scripts/add-webhook.sh teams/payments/<repo> teams/payments/<repo>

# 5) Watch discovery: Jenkins UI → teams/payments → "Scan GitLab Group now",
#    then push a commit to the repo → multibranch build starts.
```

### 11.3 Validation

```bash
# Seed jobs materialized?
curl -sk -u admin:$(grep ^JENKINS_ADMIN_PASSWORD= secrets/jenkins.env | cut -d= -f2) \
  "https://jenkins.$(grep ^PLATFORM_DOMAIN= .env | cut -d= -f2)/job/teams/api/json?tree=jobs[name]" | jq

# Organization folder discovered projects (after a scan + a repo with Jenkinsfile):
…/job/teams/job/payments/api/json?tree=jobs[name]

# A green build produces:
#  - JUnit results on the build page
#  - Sonar project "<repo>--<service>[--branch]" with gate verdict in console
#  - reports/image-<svc>.json artifact with digest
#  - image visible in Nexus UI: Browse → docker-hosted
curl -sk -u "$(grep ^NEXUS_DEPLOY_USER= secrets/nexus-jenkins.env | cut -d= -f2):$(grep ^NEXUS_DEPLOY_PASSWORD= secrets/nexus-jenkins.env | cut -d= -f2)" \
  --resolve registry.$(grep ^PLATFORM_DOMAIN= .env | cut -d= -f2):443:127.0.0.1 \
  https://registry.$(grep ^PLATFORM_DOMAIN= .env | cut -d= -f2)/v2/_catalog | jq
```

### 11.4 Troubleshooting

| Symptom | Fix |
|---------|-----|
| Org folder scan finds nothing | GitLab group path mismatch (`projectOwner` = `teams/<slug>`); project has no Jenkinsfile at root; jenkins-ci lacks group membership (Phase 4 script grants Developer on `teams`) |
| Builds trigger only hourly | Webhook not registered — run `add-webhook.sh` (D-22: hooks are an onboarding action, `manageWebHooks=false`) |
| `cannot reach BuildKit at tcp://buildkitd:1234` | buildkitd not started — `--profile build` (see 11.2 step 2) |
| Push fails `x509: certificate signed by unknown authority` | agent-general image predates CA baking — rebuild (`build-images.sh --agent general`) and recreate the warm agent container |
| Maven `deploy` 401 | Nexus credentials stale — re-run `nexus/scripts/40-users-roles.sh`, then recreate jenkins |
| `npm ERR! 402 Payment Required`/401 on publish | npm Bearer realm disabled — Nexus UI → Security → Realms → add "npm Bearer Token" (or rely on the basic-auth `.npmrc` the step writes) |
| Sonar project keys explode per branch | Expected on Community Build (D-20 branch isolation); set `sonar.projectKey` via `devsecops.yaml extra.sonarProjectKey` for a stable key |
| Quality stage fails with gate conditions listed | Working as intended — console prints each failed condition; dashboard URL in log |

### 11.5 Phase 6 completion checklist

- [x] 6 stage steps + RepoConfig (all languages of master spec §5)
- [x] Stage flags flipped: build/unitTests/integrationTests/package/imageBuild/publish
- [x] Dispatcher flag-guards (P7 steps won't be invoked until they exist)
- [x] Cross-node source transport (stash/unstash) + per-service node allocation
- [x] Organization-folder seeding via JCasC DSL (D-22) + branch-source server/credential
- [x] BuildKit image pipeline with digest capture + unique tags, no `latest` (D-23)
- [x] Release-context publication policy → Nexus hosted repos
- [x] agent-general CA trust for registry TLS
- [ ] Live end-to-end run with a sample team repo on the target host

---

## 12. DevSecOps gates (Phase 7 — final)

### 12.1 What Phase 7 adds

| Artifact | Purpose |
|----------|---------|
| `vars/scanSecrets.groovy` | gitleaks `--no-git --redact`; runs pre-build (fail fast) and/or in Security Gates (auto-deduplicated); ANY finding blocks unless excepted by RuleID **or** Fingerprint |
| `vars/runSAST.groovy` | semgrep with OFFLINE baked rulesets (`p/default`, `p/owasp-top-ten`, `p/security-audit`); ERROR→high mapping gates per policy |
| `vars/runDependencyScan.groovy` | trivy fs (lockfiles) + OWASP Dependency-Check (NVD mirror volume) → ONE merged verdict under tool `dependencies`; exceptions matched by CVE across both scanners |
| `vars/scanContainer.groovy` | trivy image **by digest** (`vuln,secret` scanners); DBs via Nexus `ghcr-proxy`; `ignore_unfixed` honored from policy (default: report, never hide) |
| `vars/generateSBOM.groovy` | syft CycloneDX + SPDX by digest; archived AND uploaded to `raw-hosted:sbom/<team>/<svc>/<digest16>.{cdx,spdx}.json`; SBOM required → hard gate |
| `vars/signImage.groovy` | cosign sign **by digest** with the platform keypair (fail-closed placeholder check); key file ephemeral, shredded in `finally` |
| `src/…/FindingGate.groovy` | the ONLY place findings become verdicts: policy `block_on_*` flags + active exceptions (owner/justification/approvedBy/expires) + log-safe output |
| `src/…/RegistryAuth.groovy` | ephemeral DOCKER_CONFIG + trivy-DB env for registry operations |
| `microservicePipeline.groovy` | new `Pre-Build Secrets Scan` stage; image-group scan/sbom/sign steps run inside `node('security')` |
| `agents/security/Dockerfile` | + Dependency-Check CLI 12.1.0, semgrep rulesets, platform CA trust |
| compose/bootstrap | `/owasp-dc` mirror volume for agent-security; `secrets/cosign.env` in jenkins env_file + placeholder |
| `security/scripts/10-cosign-keys.sh` | keypair generation via the agent image (no host cosign needed), env wiring |
| `security/scripts/20-dependency-check-db.sh` | host-side NVD mirror update (`owasp/dependency-check:12.1.0 --updateonly`, `NVD_API_KEY` honored) |
| `nexus/scripts/30-repositories.sh` | `ghcr-proxy` (ghcr.io pull-through) + docker-group member sync (idempotent upgrade for existing installs) |

### 12.2 Exact commands (target host, in order)

```bash
# 1) Rebuild + restart the security agent (new tools/CA/rules)
./scripts/build-images.sh --agent security
docker compose -f docker-compose.yml --profile agents up -d --force-recreate agent-security

# 2) Nexus: add ghcr-proxy + resync docker-group (idempotent)
./nexus/scripts/run-all.sh

# 3) NVD mirror (FIRST RUN: get a free NVD_API_KEY into .env — hours → minutes)
./security/scripts/20-dependency-check-db.sh
#    schedule nightly:
#    0 3 * * * cd /opt/devsecops-platform && ./security/scripts/20-dependency-check-db.sh >>/var/log/dc-update.log 2>&1

# 4) Cosign keypair → secrets/cosign.env
./security/scripts/10-cosign-keys.sh

# 5) Push the updated shared library to GitLab, then recreate Jenkins
docker compose -f docker-compose.yml --profile core up -d jenkins
```

### 12.3 Expected pipeline behavior

Every service build now runs: **Pre-Build Secrets Scan → Build → Unit →
Integration → Quality → Security Gates (SAST, dependencies, secrets-confirm) →
Image Build → (node security) Image Scan → SBOM → Sign → Package & Publish**.
Each gate logs a normalized verdict line:

```
[Security Gates] tool=container findings=23 critical=0 high=2 medium=15 low=6 excepted=2 blocking=0
[Security Gates] ALLOWED by exception register: CVE-2025-00000 (…) — expires per security-exceptions.yaml
```

Blocking findings print `BLOCKING <SEVERITY>: <id> — <file/pkg detail>` (max 15,
full list in the archived JSON) and fail the build with the policy reason.

### 12.4 Validation

```bash
# NVD mirror populated:
ls -lh $DATA_ROOT/security/dependency-check/odc.mv.db
# ghcr-proxy serves the trivy DB (through docker-group):
curl -sk -u <NEXUS_DEPLOY_USER>:<NEXUS_DEPLOY_PASSWORD> \
  --resolve registry.$PLATFORM_DOMAIN:443:127.0.0.1 \
  "https://registry.$PLATFORM_DOMAIN/v2/aquasecurity/trivy-db/tags/list"
# cosign keypair consistent:
grep -c COSIGN_KEY= secrets/cosign.env && ls -l secrets/cosign/
# after a green build — signature present:
cosign verify --certificate-identity-regexp '.*' --key secrets/cosign/cosign.pub \
  registry.$PLATFORM_DOMAIN/<team>/<svc>@<digest>   # or check the sign-<svc>.json artifact
# SBOM in Nexus: Browse → raw-hosted → sbom/<team>/<svc>/
```

### 12.5 Troubleshooting

| Symptom | Fix |
|---------|-----|
| DC fails: "data directory EMPTY" | run `security/scripts/20-dependency-check-db.sh` (first run without NVD key can take hours — set `NVD_API_KEY`) |
| trivy: `failed to download DB … 401/404` | ghcr-proxy missing or not in docker-group → re-run `nexus/scripts/run-all.sh`; auth = nexus-deploy creds (step handles) |
| trivy DB slow first scan | normal: ghcr-proxy caches on first pull; subsequent scans hit the Nexus cache |
| semgrep: no findings at all, rc 0 | rules dir missing (agent image not rebuilt) → `build-images.sh --agent security` |
| gitleaks rc≠0 with no report | workspace path issue — step runs `--no-git` on `svc.path`; check console for the gitleaks error |
| cosign: "placeholder" error | run `security/scripts/10-cosign-keys.sh` + recreate jenkins |
| signImage fails x509 | agent-security image predates CA baking → rebuild + recreate the agent container |
| Exception not honored | register entry must match tool name exactly (`secrets`/`sast`/`dependencies`/`container`) and the finding id (CVE / check_id / RuleID / Fingerprint); expired exceptions gate again BY DESIGN |

### 12.6 Phase 7 completion checklist

- [x] 6 security steps + FindingGate/RegistryGate helpers (policy-driven, log-safe)
- [x] Pre-build secrets stage + dedupe with the Security Gates stage
- [x] Offline semgrep rules baked; trivy DBs via Nexus ghcr-proxy; NVD mirror host-updated
- [x] Dependency-Check CLI 12.1.0 pinned in agent AND updater image (H2 schema)
- [x] SBOM (CycloneDX+SPDX) archived + uploaded to raw-hosted by digest
- [x] cosign keypair provisioning + signing by digest + fail-closed placeholders (D-25)
- [x] Flags ON: preBuildSecurity, sast, dependencyScan, secrets, imageScan, sbom, sign
- [ ] Live end-to-end scan run + nightly NVD timer enabled on target host

---

## 13. Phase 8 — Kubernetes / GitOps deployment plane

Prerequisites (host tools, pinned like the agent images — one-liners in
`kubernetes/README.md`): `kubectl v1.35.10`, `helm v3.22.1`, `yq v4.54.1`,
`argocd v3.4.8`, `jq`. Platform state: compose core+agents running, GitLab
provisioned (`gitlab/scripts/run-all.sh`), Nexus configured
(`nexus/scripts/run-all.sh`), cosign keypair generated
(`security/scripts/10-cosign-keys.sh`), Vault initialized+unsealed with the
root token stored:

```bash
echo "VAULT_ROOT_TOKEN=<from vault operator init>" > secrets/vault-root.env
chmod 600 secrets/vault-root.env
```

### 13.1 Command sequence

```bash
# 1) Nexus: adds quay-proxy + syncs docker-group members (idempotent re-run)
./nexus/scripts/run-all.sh

# 2) GitLab: sync real content into platform/gitops-repository
#    (chart, sample app, clusters/) + verify gitops-write / argocd-read PATs
./gitlab/scripts/50-gitops-repository.sh

# 3) Deployment plane (Option B lab; needs root — installs K3s, ArgoCD,
#    Kyverno, ESO, Vault k8s-auth, verifier kubeconfig; ~5–10 min)
sudo -E ./kubernetes/scripts/00-bootstrap-cluster.sh
#    Option A (existing cluster): point kubectl at it, then
#    sudo is not needed:  SKIP_K3S=1 ./kubernetes/scripts/00-bootstrap-cluster.sh

# 4) CI plane picks up the new env + flags (gitops/sync are ON in
#    platform-config; casc adds platform/gitops-promotion):
docker compose -f docker-compose.yml --profile core --profile agents up -d jenkins agent-general

# 5) Publish the updated shared library (updateGitOps/deployApplication/
#    promoteDigest + GitOpsRepo + platform-config) — same flow as §12 step 6.
```

### 13.2 Expected outputs

* `00-bootstrap-cluster.sh` ends with the `Deployment plane READY` banner
  (ArgoCD URL, policies Enforce, ESO→Vault store).
* `kubectl get nodes` → one Ready node (K3s v1.36.5+k3s1).
* `kubectl -n argocd get applications` → `platform-root` + `orders-api-{dev,qa,uat,prod}`
  (the sample app syncs immediately; `orders-api-dev` pods will CrashLoop until
  a real image digest is promoted — the zeros placeholder is intentional and
  Kyverno-visible).
* `kubectl get clusterpolicy` → `verify-image-signature`, `require-digest-pinning` (ready).
* `kubectl get clustersecretstore vault-cluster-store` → `Ready=True` (after step 3's
  Vault wiring).
* Jenkins → `platform/gitops-promotion` job exists (4 parameters).

### 13.3 Validation

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl -n argocd exec deploy/argocd-server -- argocd app list -o name | head   # apps generated
kubectl run sigtest --image=registry.${PLATFORM_DOMAIN}/orders/orders-api:managed-by-gitops \
  --restart=Never --dry-run=server -o name -n orders-api-dev 2>&1 | grep -i "digest"   # rejected: mutable tag
vault read auth/kubernetes-${K8S_CLUSTER_NAME:-lab-k3s}/role/eso-reader          # bound SA/namespace
source secrets/argocd.env && curl -sk "${ARGOCD_SERVER_URL}/healthz"             # live from host
```

End-to-end: build a real service on `main` → watch **GitOps & Deploy** stage →
`argocd app get <slug>-dev` → `kubectl -n <slug>-dev get pods` (image ref shows
`@sha256:`, signature verified, ExternalSecret synced).

### 13.4 Troubleshooting

See `documentation/gitops.md` §8 (full table: repo credentials, ApplicationSet
generation, Kyverno rejections, pull 401s, ESO store states, deploy timeouts).

- [x] K3s pinned v1.36.5+k3s1 (traefik/servicelb disabled, Nexus mirrors + CA + auth)
- [x] ArgoCD v3.4.8: NodePort, jenkins-cd RBAC (get/sync only), root app-of-apps, ApplicationSets
- [x] gitops-repository: chart + orders-api sample + 4 env overlays (render & commit, D-26)
- [x] Kyverno v1.19.2: verify-image-signature (inline cosign.pub) + require-digest-pinning (Enforce)
- [x] ESO chart 2.14.0 + ClusterSecretStore → Vault KV v2 (k8s auth per cluster, policy apps/* only)
- [x] Jenkins: updateGitOps / deployApplication / promoteDigest + platform/gitops-promotion job
- [x] Secrets chain: gitops-write + argocd-read PATs, argocd.env, k8s.env (read-only verifier)
- [x] Flags ON: gitops, sync — verify/postDeploy stay OFF (Phase 9)
- [ ] Live cluster run on target hardware (sandbox validated statically + helm/kustomize renders)

---

## 14. Phase 9 — Advanced deployment (progressive delivery + verification)

New components: **Argo Rollouts v1.10.1** (canary/blue-green), chart **1.1.0**
(optional `Rollout` workload), k6 **v2.3.0** + Node **v22.23.4** + Newman
**6.2.3** on agent-general, verifier RBAC extended (rollouts/ESO read +
`pods/portforward` create — the identity's only active verb), and the
`verify`/`postDeploy` stage flags ON.

### 14.1 Command sequence

```bash
# 1) cluster: Argo Rollouts (also runs inside 00-bootstrap-cluster.sh now)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
./kubernetes/rollouts/install-argo-rollouts.sh

# 2) verifier identity refresh (ClusterRole gained rollouts/ESO/portforward)
./kubernetes/scripts/20-verify-kubeconfig.sh

# 3) rebuild agent-general (k6 + node + newman baked) and recreate consumers
./scripts/build-images.sh --agent general
docker compose -f docker-compose.yml --profile core --profile agents up -d jenkins agent-general

# 4) sync the chart 1.1.0 + orders-api Rollout overlays to the gitops repo
./gitlab/scripts/50-gitops-repository.sh

# 5) publish the updated shared library (verifyDeployment / runPostDeploy /
#    rollbackDeployment / KubeAccess + platform-config flags) — same flow as §12.
```

### 14.2 Expected pipeline behavior

* **Verify & Post-Deploy** stage appears after GitOps & Deploy (agent-general):
  workload convergence (`rollout status` / Rollout `phase=Healthy`),
  readyReplicas, **pod image == this build's signed digest**, pathology scan,
  warning events, ExternalSecret readiness — then newman/k6 smoke tests if the
  service repo has `tests/postman/*.postman_collection.json` / `tests/k6/*.js`
  (BASE_URL via port-forward; loud skip when absent).
* Failure path (with `gitops.autoRollback: true`): the PREVIOUS digest from the
  overlay's own git history is re-pinned (`revert(gitops): rollback …` commit),
  ArgoCD reconciles back, and the build still FAILS — rollback restores the
  service, it never forgives the change.
* orders-api ships as a canary Rollout: dev/qa 50%→100% (10s pause),
  uat 25/50/100 (30s), prod 10/30/60/100 (3×2m) — bounded pauses so
  `verifyDeployment` reaches `Healthy` inside its timeout.

### 14.3 Validation

```bash
kubectl get crd rollouts.argoproj.io                          # CRD present
kubectl -n argo-rollouts get deploy argo-rollouts             # 1/1 (lab)
kubectl auth can-i create pods/portforward -A \
  --as=system:serviceaccount:platform-tools:deploy-verifier   # yes
kubectl auth can-i delete pods -A \
  --as=system:serviceaccount:platform-tools:deploy-verifier   # no
kubectl auth can-i create pods/exec -A \
  --as=system:serviceaccount:platform-tools:deploy-verifier   # no
```

- [x] Argo Rollouts v1.10.1 pinned install (lab replicas=1) + bootstrap wired
- [x] Chart 1.1.0: Rollout (canary/blueGreen + preview service), shared podTemplate, HPA follows kind
- [x] Kustomize CRD gotchas solved & PROVEN by live builds: replicas via per-overlay
      `replicas-config.yaml` (built-ins exclude Rollout; no `kind:` field exists in v5.8.3),
      pod-template LIST edits via JSON6902 (CRD = JSON-merge; strategic containers
      patch clobbers the list)
- [x] verifyDeployment: convergence + replicas + digest-identity + pathology + ESO readiness
- [x] runPostDeploy: newman/k6 discovery conventions, port-forward BASE_URL, loud skip, thresholds
- [x] rollbackDeployment: file-scoped git-history digest revert + wait; auto-wired via gitops.autoRollback
- [x] Verifier RBAC extended read-only + pods/portforward (no exec/attach) — can-i proofs above
- [x] Flags ON: verify, postDeploy — ALL 20 pipeline stages now active
- [ ] Live canary run on target hardware (sandbox validated renders/builds/RBAC statically)

---

## 15. Phase 10 — Observability (make the monitoring profile operational)

Full architecture + runbooks: `documentation/observability.md`.

### 15.1 Command sequence

```bash
# 1) secrets + placeholder files (idempotent; adds alertmanager/prometheus/jenkins-notification files)
./scripts/bootstrap.sh

# 2) recreate services whose config/networks changed
docker compose --profile all up -d prometheus alertmanager loki alloy grafana jenkins gitlab

# 3) Nexus scrape target (capability + zero-priv 'metrics' user; after Phase 5 admin bootstrap)
./monitoring/scripts/10-enable-nexus-metrics.sh
docker compose exec prometheus kill -HUP 1

# 4) real notification endpoints (fill SMTP_*/SLACK_WEBHOOK_URL/TEAMS_WEBHOOK_URL
#    in .env first; prompts for SMTP password)
./monitoring/scripts/20-configure-notifications.sh
docker compose up -d jenkins

# 5) publish the shared library again (notify hooks in verify/rollback/postDeploy
#    + platform-config comment/flag semantics) — same flow as §12/§13.
```

### 15.2 Validation

```bash
# Prometheus/Alertmanager are Traefik-routed behind the monitoring-auth
# basic-auth middleware; Loki is internal-only — query from inside the stack:
docker compose exec prometheus wget -qO- http://localhost:9090/api/v1/targets | \
  jq -r '.data.activeTargets[] | "\(.labels.job) \(.health)"' | sort -u
docker compose exec prometheus wget -qO- http://localhost:9090/api/v1/rules | jq -r '.data.groups[].name'
#   → platform-availability host-resources watchdog cicd-* slo:records slo:alerts
docker compose exec alertmanager wget -qO- http://localhost:9093/api/v2/alerts | \
  jq -r 'map(.labels.alertname) | unique'                       # Watchdog firing
docker compose exec loki wget -qO- http://localhost:3100/prometheus/api/v1/rules | \
  jq -r '.data.groups[].name'                                   # platform-log-alerts
GF_PW=$(grep GF_SECURITY_ADMIN_PASSWORD secrets/grafana.env | cut -d= -f2)
curl -s -u "admin:$GF_PW" "https://grafana.${PLATFORM_DOMAIN}/api/search?query=DevSecOps" | jq length   # 5
```

- [x] jenkins joined monitoring-network (job 'jenkins' reachable at last)
- [x] gitlab-exporter (exporters-only omnibus mode — bundled prometheus/grafana OFF)
- [x] nexus metrics capability + zero-priv account + password_file (config always loads)
- [x] rules: cicd.yml (jenkins/gitlab/vault/nexus/loki), slo.yml (recording + burn-rate), Watchdog
- [x] Alertmanager receivers live: Slack + MSTeams + SMTP via *_file secrets; SIGHUP reload
- [x] Loki embedded ruler: 3 log-alerts from monitoring/loki/rules/fake/
- [x] Alloy drops healthcheck noise pre-ingestion
- [x] 5 Grafana dashboards provisioned (overview/SLOs, CI/CD, infra, security+vault, logs)
- [x] notifyResult hooks: deployment_failed (verify+postDeploy), rollback_executed (auto+manual)
- [x] 20-configure-notifications.sh: single script for both paths, per-channel enablement
- [ ] Live end-to-end alert test on target hardware (test-alert curl in observability.md §7)

---

## 16. Phase 11 — Enterprise hardening (Vault dynamic secrets, DR, realm cutover, TLS)

Full runbooks: `documentation/backup-recovery.md` (DR), `security.md` §7–9
(Vault/realm/TLS), `performance.md` (capacity).

### 16.1 Command sequence

```bash
# 1) refresh secrets contracts + recreate touched services
./scripts/bootstrap.sh
docker compose --profile all up -d jenkins alloy traefik

# 2) Vault (requires: initialized + UNSEALED; VAULT_ROOT_TOKEN in secrets/vault-root.env)
./vault/scripts/40-platform-secrets.sh      # seed secret/platform/{notifications,cosign}
./vault/scripts/50-jenkins-approle.sh       # role-id/secret-id → JCasC 'vault-approle'
./vault/scripts/60-audit-enable.sh          # audit → Alloy tail → Loki vault-audit
docker compose up -d jenkins                # picks up secrets/vault-jenkins.env

# 3) backups: cron/systemd timer → scripts/backup-now.sh (native dumps + restic)
#    first full cycle now:
./scripts/backup-now.sh
./scripts/restore.sh list

# 4) TLS hardening is config-only (dynamic.yml.tmpl): re-render + restart
./scripts/bootstrap.sh && docker compose restart traefik

# 5) OPTIONAL realm cutover (LDAP/OIDC): security.md §8 — mount one of
#    jenkins/optional-casc/10-security-{ldap,oidc}.yaml over 10-security.yaml
```

### 16.2 Validation

```bash
# Vault: approle login reads platform secrets, nothing else
docker compose exec -T vault vault write -f auth/approle/login \
  role_id=… secret_id=… -field=token                       # → 1h client token
#   kv get secret/platform/notifications  → OK
#   kv get secret/apps/orders-api/db-creds → permission denied (least privilege)
docker compose exec vault vault audit list                 # file/ enabled=true
docker compose exec loki wget -qO- 'http://localhost:3100/loki/api/v1/labels' | jq   # service includes vault-audit

# Backups
./scripts/restore.sh list                                  # manual-<ts> snapshot present
ls $DATA_ROOT/vault/file/snapshot-*.db                     # raft snapshots (≤3)
ls $DATA_ROOT/gitlab/data/backups/                         # gitlab tars (≤3)
ls $DATA_ROOT/backups/native/sonar/                        # pg dumps (≤3)
ls $DATA_ROOT/nexus-data/backups/db/                       # nexus db backups (≤3)

# TLS
echo | openssl s_client -connect gitlab.<domain>:443 2>/dev/null | grep -E "Protocol|Cipher"
#   → TLSv1.2/1.3 with ECDHE-*-GCM or CHACHA20 only

# Realm (only if cut over): login via LDAP/OIDC + escape-hatch/break-glass tested
```

- [x] Vault: jenkins-platform policy + AppRole (1h tokens) + platform secret seeding + audit device
- [x] Jenkins: vault-approle credential live via env contract + global vaultConfiguration (withVault ready)
- [x] Audit log → Loki (Alloy file tail, service=vault-audit)
- [x] Native consistent dumps ×4 (vault raft / gitlab / sonar pg / nexus task) + pruning + on-demand backup-now
- [x] restore.sh: files / vault-raft / gitlab / sonar-db / all + full-DR runbook (backup-recovery.md)
- [x] Off-host restic repository + password rotation runbooks
- [x] LDAP + OIDC realm cutover kits (optional-casc, pinned oic-auth, break-glass escape hatch)
- [x] TLS: AEAD-only cipher suites + curve preferences (Traefik dynamic config)
- [x] performance.md: sizing map, tier capacity, bottleneck analysis, load-verification procedure
- [ ] Quarterly restore drill scheduled on target hardware (backup-recovery.md §8)
