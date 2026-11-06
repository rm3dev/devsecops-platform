# 🚀 GETTING STARTED — Run, Configure & Understand the Platform

> **What this document is:** the single operational manual. Follow it top to
> bottom on a fresh machine and you will end with the entire DevSecOps
> platform RUNNING, a sample microservice deployed to Kubernetes through the
> full 20-stage pipeline, backups scheduled, and notifications live.
> Every step: **command → what it does → how long → ✅ verify → ⚠️ if it fails**.
>
> **How it differs from the other docs:**
> - `LEARNING-GUIDE.md` teaches you *why* (4-day course, exercises, quizzes)
> - `installation.md` is the per-phase reference (deepest detail)
> - **this guide is the straight line through everything, in order**
>
> **Time budget:** 4–6 hours of wall-clock (much of it waiting for GitLab and
> image builds — reading time included). Nothing here requires prior DevOps
> experience, only comfort with a Linux terminal.

---

## 1. What you are about to run (60 seconds)

A **self-hosted software factory + deployment platform**:

- **World 1 — Control plane** (Docker Compose, one host): GitLab (code),
  Jenkins (pipelines), SonarQube (quality), Nexus (artifacts + Docker
  registry), Vault (secrets), Traefik (HTTPS edge), Prometheus/Grafana/Loki/
  Alertmanager (observability), restic (backups).
- **World 2 — Deployment plane** (Kubernetes; K3s for labs): ArgoCD deploys
  from a **gitops-repository** (Helm chart + per-environment overlays),
  Argo Rollouts does canary releases, Kyverno refuses unsigned images,
  External Secrets Operator pulls app secrets from Vault.

A code push travels: **build → test → quality gate → security scans → signed
container image → git commit pinning the image digest → ArgoCD sync →
in-cluster verification → smoke tests → (auto-rollback on failure) →
notification**. You'll see all of it in Step 11.

---

## 2. Prerequisites checklist

### 2.1 Hardware (lab tier)

| Resource | Minimum | Comfortable |
|---|---|---|
| CPU | 8 cores | 16 cores |
| RAM | 24 GB | 32–64 GB |
| Disk | 80 GB free **SSD** | 150 GB NVMe |
| OS | Any modern Linux with Docker (Ubuntu 22.04+/Debian 12+/Fedora tested patterns) | same |

GitLab alone wants ~4 GB; the full stack idles around 12–16 GB resident.

### 2.2 Software

```bash
docker --version          # ≥ 24.x
docker compose version    # ≥ 2.20 (the plugin, not docker-compose v1)
git curl jq openssl wget  # install via your package manager if missing
```

For the Kubernetes side (Step 7, K3s option): root/sudo on the same host (or a
second host), and ports **6443** + **30443** free.

### 2.3 Network / DNS

Pick a base domain — for a lab, `devops.local` is fine. Every UI is reached as
`<service>.<domain>` through Traefik. Either:

- **Real DNS** (recommended if you have a domain): wildcard A record
  `*.devops.example.com → your host IP`, or
- **/etc/hosts** on every machine that will use the platform:

```bash
echo "127.0.0.1 gitlab.devops.local jenkins.devops.local sonar.devops.local nexus.devops.local vault.devops.local grafana.devops.local prometheus.devops.local alertmanager.devops.local registry.devops.local traefik.devops.local argocd.devops.local" | sudo tee -a /etc/hosts
```

Which names actually route: the eight service names (gitlab, jenkins, nexus,
sonar, vault, grafana, prometheus, alertmanager) serve Web UIs through
Traefik; `registry.` is the Docker Registry **API** (a browser sees a JSON
401 — that is healthy, not a website); `traefik.` never routes (dashboard is
internal-only by design); `argocd.` does NOT route through Traefik either —
ArgoCD is NodePort-direct at `https://<node-ip>:30443` (D-27). The last two
are in the line anyway so DNS stays uniform across machines and a future
Traefik router for ArgoCD needs no hosts changes.

TLS: the platform generates its **own internal CA + wildcard certificate**.
Browsers will warn until you import `reverse-proxy/certificates/ca.crt`
(Step 4.6). Kubernetes nodes get this CA automatically (Step 7).

### 2.4 Optional externals (can be added later, platform works without)

| Thing | Used for | Needed when |
|---|---|---|
| SMTP server (host/user/password) | email notifications | Step 9 |
| Slack incoming webhook URL | notifications | Step 9 |
| MS Teams workflow webhook URL | notifications | Step 9 |
| Free NVD API key (nvd.nist.gov) | fast vulnerability-db builds | Step 5.4 (hours→minutes) |
| Off-host backup target (sftp/rest/s3) | real DR | Step 10 |

✅ **Checkpoint 2:** docker hello-world runs; hosts/DNS resolves
`gitlab.<domain>` to your host; ports 6443/30443 free.

---

## 3. Step 0 — Get the code

```bash
git clone https://github.com/rm3dev/devsecops-platform.git
cd devsecops-platform
```

Everything below assumes you are in this directory. **The repo is the
platform**: compose files, configs, automation scripts, the Jenkins pipeline
library, the Helm chart, dashboards, alert rules, docs. Nothing is installed
from random internet sources at runtime — every image/version is pinned in
`.env.example` and verified.

Quick orientation (you'll meet each of these again):

```
docker-compose.yml        the whole control plane (14 services, 8 networks)
.env.example              every knob, commented          → becomes .env
scripts/                  bootstrap, build, health, backup/restore
jenkins/                  controller image, JCasC config, shared library, agents
gitlab/ sonarqube/ nexus/ vault/ security/   per-tool API automation scripts
monitoring/               prometheus rules, grafana dashboards, loki, alloy
kubernetes/               K3s installer + cluster bootstrap (ArgoCD, Kyverno…)
gitops-repository/        Helm chart + applications + cluster definitions
reverse-proxy/            Traefik static/dynamic config + certificates
documentation/            this guide + 9 deep-dive docs
```

---

## 4. Step 1 — Configure `.env` (the single config surface)

```bash
cp .env.example .env
nano .env
```

The file has ~90 variables in commented groups. **For a first lab run you only
MUST change 2–3**; the rest have working defaults. Group by group:

### 4.1 Must edit

| Variable | Set to | Why |
|---|---|---|
| `PLATFORM_DOMAIN` | `devops.local` (or your domain) | every URL, cert, and route derives from it |
| `DATA_ROOT` | e.g. `/mnt/data/devsecops` | ALL persistent state lives here (SSD!) — create it: `mkdir -p /mnt/data/devsecops` |
| `TZ` | your timezone (default `Asia/Calcutta` in the example) | log timestamps, backup schedules |

### 4.2 Understand-but-leave-alone groups

- **Version pins** (`GITLAB_VERSION`, `JENKINS_VERSION`, `PROMETHEUS_VERSION`,
  …): frozen, mutually-tested versions. Change only deliberately, one at a
  time, after reading release notes.
- **Sizing** (`*_CPU_LIMIT`, `*_MEM_LIMIT`, `JENKINS_JAVA_XMX`,
  `GITLAB_SSH_PORT`): resource ceilings per service. On a small host, the
  installation doc §3 lists a reduced profile; defaults target the 32 GB tier.
- **Retention** (`PROM_RETENTION_TIME=15d`, `PROM_RETENTION_SIZE=30GB`,
  `LOKI_RETENTION_PERIOD=336h`, `BACKUP_*`): how long metrics/logs/backups live.
- **Notification endpoints** (`SMTP_*`, `SLACK_WEBHOOK_URL`,
  `TEAMS_WEBHOOK_URL`, mailboxes): leave EMPTY for now — Step 9 activates
  exactly the channels you fill in. Empty = disabled, never broken.
- **`RESTIC_REPOSITORY_LOCAL=/backups/repo`**: backups land inside DATA_ROOT.
  For real environments add `RESTIC_REPOSITORY=sftp:…` (Step 10).

⚠️ **Rule of thumb:** never put a *password* in `.env` — the platform
generates all secrets itself (next step). `.env` is configuration, not
credentials. (`.env` is gitignored anyway.)

✅ **Checkpoint 4:** `grep -E "^PLATFORM_DOMAIN|^DATA_ROOT" .env` shows your
values; `DATA_ROOT` directory exists and is owned by you.

---

## 5. Step 2 — Bootstrap (secrets, CA, rendered configs)

```bash
./scripts/bootstrap.sh
```

**What it does (idempotent — safe to re-run always):**
1. validates `.env` and tool availability,
2. creates the `DATA_ROOT` directory tree,
3. **generates every initial secret** into `secrets/` (mode 0600, gitignored):
   GitLab root password, Jenkins admin + 6 role passwords, Sonar DB, Grafana
   admin, restic encryption key, webhook tokens, and `SET_IN_PHASE_N`
   placeholders for credentials that later scripts will fill (fail-closed:
   anything touching a placeholder errors loudly with the fix),
4. creates the **internal Certificate Authority + wildcard TLS cert** in
   `reverse-proxy/certificates/`,
5. renders Traefik's dynamic routing config from the template.

**Verify:**

```bash
ls -la secrets/ | head            # ~12 files, all -rw-------
ls reverse-proxy/certificates/    # ca.crt ca.key platform-wildcard.crt/.key
./scripts/validate.sh             # static validation of the whole repo
```

⚠️ **If it fails:** it's almost always `.env` (typo, DATA_ROOT not writable).
Fix and re-run — idempotent means no harm.

---

## 6. Step 3 — Build the custom images (15–40 min)

```bash
./scripts/build-images.sh
```

Builds the **Jenkins controller** (LTS + 29 pinned plugins from
`jenkins/plugins.txt`, JCasC-ready) and the **7 agent images** (general,
python, java-maven, java-gradle, dotnet, nodejs, security). Every tool inside
is version-pinned (kubectl, helm, kustomize, trivy, semgrep, cosign, k6,
newman, …). `buildkitd` (the rootless image builder) uses its pinned upstream
image directly.

**Verify:** `docker images | grep -c devsecops` → ≥ 8 images.

💡 While this runs, read `jenkins/Dockerfile` and
`jenkins/agents/general/Dockerfile` — 20 minutes that pays off forever.

---

## 7. Step 4 — Start the control plane (staged, ~15 min)

Services are grouped into **profiles** so you can start (and understand) them
in layers:

```bash
# Layer 1 — the factory core (GitLab is slow: first boot 5–10 min)
docker compose --profile core up -d
#   traefik gitlab jenkins sonarqube-db sonarqube nexus vault

# Layer 2 — the nervous system
docker compose --profile monitoring up -d
#   prometheus alertmanager grafana loki alloy node-exporter cadvisor

# Layer 3 — the workers + insurance
docker compose --profile agents up -d      # agent-general/python/security (warm pool)
docker compose --profile backup up -d      # restic backup loop
docker compose --profile build up -d       # buildkitd + docker-socket-proxy
```

**Watch it come up** (the only correct way — healthchecks, not vibes):

```bash
watch -n5 'docker compose ps --format "table {{.Name}}\t{{.Status}}"'
# wait until everything says (healthy); GitLab takes longest (start_period 600s)
./scripts/health-check.sh                  # platform's own verdict
```

### 4.5 Log into everything (credential treasure hunt)

| UI | URL | Username | Password location |
|---|---|---|---|
| GitLab | `https://gitlab.<domain>` | `root` | `secrets/gitlab.env` → `GITLAB_ROOT_PASSWORD` |
| Jenkins | `https://jenkins.<domain>` | `admin` | `secrets/jenkins.env` → `JENKINS_ADMIN_PASSWORD` |
| SonarQube | `https://sonar.<domain>` | `admin` | first login `admin/admin` → Step 5.2 rotates it into `secrets/sonar.env` |
| Nexus | `https://nexus.<domain>` | `admin` | first-boot file: `docker compose exec nexus cat /nexus-data/admin.password` → Step 5.3 rotates it |
| Vault | `https://vault.<domain>` | — | sealed until Step 6 |
| Grafana | `https://grafana.<domain>` | `admin` | `secrets/grafana.env` |
| Prometheus / Alertmanager | `https://prometheus.<domain>` etc. | basic-auth | `secrets/monitoring.env` |
| Traefik dashboard | `https://traefik.<domain>/dashboard/` | basic-auth | `secrets/monitoring.env` |

The six Jenkins role accounts (`platform-admin`, `devops-admin`, `developer`,
`security-engineer`, `release-manager`, `app-owner`) also live in
`secrets/jenkins.env` — they demonstrate the RBAC matrix (Manage Jenkins →
Security).

### 4.6 Trust the certificate (once per client machine)

Import `reverse-proxy/certificates/ca.crt` into your OS/browser trust store →
all padlocks turn green. (Linux: copy to
`/usr/local/share/ca-certificates/devsecops-ca.crt && sudo update-ca-certificates`.)

✅ **Checkpoint 7:** `health-check.sh` all-green; you are logged into 6 UIs;
Jenkins → Manage Jenkins shows JCasC applied with no errors (the
`platform-admin` etc. users exist).

⚠️ **Common failures:**
- *GitLab restart-looping:* it needs ~4 GB; check `GITLAB_MEM_LIMIT` vs free
  RAM, `docker compose logs gitlab | tail -40`.
- *Something "unhealthy" but logs look fine:* healthchecks have start periods;
  give Prometheus/Loki 90 s, Jenkins 4 min, GitLab 10 min before debugging.
- *Port conflicts (80/443/5000…):* `sudo ss -tlnp | grep -E ':80 |:443 '`,
  free them or remap Traefik's ports in compose.

---

## 8. Step 5 — Initialize the toolchain (each tool configures itself via API)

All scripts are idempotent and use the service APIs — no clicking in UIs.

### 8.1 GitLab (users, groups, projects, webhooks, seed repos) — ~2 min

```bash
./gitlab/scripts/run-all.sh
```

What it creates: a root API token; the `platform` group; service users
(`jenkins-ci` with a least-privilege PAT, `gitops-write`); protected
branches/tags; the **`platform/devsecops-shared-library`** repo (seeded from
`jenkins/shared-library/` — this is where Jenkins loads the pipeline from) and
the `platform/gitops-repository` skeleton; sample team repos incl. an
**orders-api** sample service.

✅ Verify: GitLab UI shows the `platform` group with seeded projects;
`secrets/gitlab-jenkins.env` no longer says `SET_IN_PHASE_4`.

### 8.2 SonarQube (admin rotation, quality gates, CI token) — ~1 min

```bash
./sonarqube/scripts/run-all.sh
```

Creates the `devsecops-default` + `devsecops-strict` quality gates and the
token Jenkins uses (`secrets/sonar-jenkins.env`).

### 8.3 Nexus (admin rotation, 17 repositories, cleanup, CI account) — ~2 min

```bash
./nexus/scripts/run-all.sh
```

Creates: hosted+proxy repos for maven/npm/pypi/nuget/raw/docker, a
`docker-group` (single pull endpoint), `ghcr-proxy`, 6 cleanup policies, and
the `jenkins-ci` deploy account with a least-privilege role
(`secrets/nexus-jenkins.env`).

### 8.4 Security tooling — NVD mirror + signing keys — 5 min…4 h

```bash
./security/scripts/20-dependency-check-db.sh   # builds the CVE mirror
./security/scripts/10-cosign-keys.sh           # image-signing keypair → secrets/cosign.env
```

⚠️ The NVD download takes HOURS without an API key. Get a free key from
nvd.nist.gov, put `NVD_API_KEY=…` in `.env`, re-run → minutes. Schedule the
nightly refresh (cron line printed by the script and in installation.md §12).

### 8.5 Recreate Jenkins to pick up all new credentials

```bash
docker compose --profile core up -d --force-recreate jenkins
```

JCasC reads the `secrets/*.env` files **at startup** — this is why every
"provisioning" step ends with a Jenkins recreate. (You'll see this pattern
again in Steps 6 and 9.)

✅ **Checkpoint 8:** Nexus → Repositories lists ~17; Sonar → Quality Gates
shows both gates; GitLab `platform/` group populated; Jenkins restarted clean
(`docker compose logs jenkins | grep -i "casc"` shows no SEVERE).

---

## 9. Step 6 — Vault: initialize, unseal, wire (the secrets bank)

Vault ships **sealed and uninitialized** — by design (never dev-mode, D-09).

### 9.1 One-time initialization

```bash
docker compose exec vault vault operator init -key-shares=5 -key-threshold=3
```

It prints **5 unseal keys + 1 initial root token**. ⚠️ **THE MOST IMPORTANT
30 SECONDS OF THIS GUIDE:** store the 5 keys and the root token OFF this
machine (password manager, sealed envelopes in a safe). They are never backed
up by the platform, on purpose. Lose 3+ keys = lose every secret forever.

```bash
# record them, then:
printf 'VAULT_ROOT_TOKEN=<your-root-token>\n' > secrets/vault-root.env && chmod 600 secrets/vault-root.env
```

Older Vault releases left the vault **unsealed** right after init — Vault 2.x
with raft storage does NOT (verified live on 2.2.1: `initialized: true,
sealed: true` immediately after init). So unseal now, and after *every*
restart, with 3 of the 5 keys:

```bash
docker compose exec vault vault operator unseal     # run 3×, pasting a key each time
```

### 9.2 Wire Vault into the platform

```bash
./vault/scripts/40-platform-secrets.sh    # seed secret/platform/{notifications,cosign} from .env/secrets
./vault/scripts/50-jenkins-approle.sh     # Jenkins' machine identity: 1h tokens, read-only policy
./vault/scripts/60-audit-enable.sh        # audit log → Alloy tails it → Loki (service=vault-audit)
# env_file is read at container CREATE time — a plain up -d/restart keeps the
# OLD env; recreate so Jenkins actually sees secrets/vault-jenkins.env:
docker compose --profile core up -d --force-recreate jenkins
```

✅ **Checkpoint 9:** `docker compose exec vault vault status` shows
`Sealed: false`; the 50-script's final line reads *verified: approle login →
1h client token → notifications read*.

---

## 10. Step 7 — The Kubernetes deployment plane

Two options — pick ONE:

### Option B first (lab): install K3s on this host

```bash
sudo ./kubernetes/k3s/install-k3s.sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml      # add to ~/.bashrc
kubectl get nodes                                 # ✅ one Ready node
```

What the installer does (read it — 150 lines of teaching material): pinned K3s
with its **built-in Traefik disabled** (ours is the edge; two ingress
controllers fight over 80/443), node `/etc/hosts` + CA trust for
`vault.<domain>` (ESO must reach Vault), and `registries.yaml` mirroring
docker.io/quay.io/ghcr.io **through Nexus** (nodes never pull from the
internet directly).

### Option A (production): register an existing cluster

```bash
./kubernetes/scripts/10-register-cluster.sh
```

### Then, for either option — bootstrap the cluster tooling (~5 min)

```bash
./kubernetes/scripts/00-bootstrap-cluster.sh
```

Installs, in order (each a readable, idempotent script under `kubernetes/`):
1. **ArgoCD** (NodePort 30443; admin password → `secrets/argocd.env`; a
   least-privilege `jenkins-cd` API account; the app-of-apps root)
2. **Kyverno** + our two ENFORCE policies: `verify-image-signature` (cosign
   public key inline) and `require-digest-pinning` (`@sha256:` or refused)
3. **Argo Rollouts** (canary/blue-green controller)
4. **External Secrets Operator** + per-cluster Vault Kubernetes auth
   (`vault/scripts/30-k8s-auth.sh`: TokenReview identity, `eso-reader` role —
   no static Vault tokens in the cluster)
5. **The read-only verifier identity** (`20-verify-kubeconfig.sh` →
   `secrets/k8s.env` → Jenkins): may get/list workloads/pods/events +
   port-forward (for smoke tests) — nothing else.

```bash
docker compose --profile core up -d --force-recreate jenkins  # env_file is read at CREATE time — plain up -d/restart keeps the old env
kubectl get pods -A | grep -Ev "Running|Completed"   # ✅ empty within ~2 min
```

✅ **Checkpoint 10:** ArgoCD UI at `https://argocd.<domain>` (or
`https://<node-ip>:30443`) — login `admin` / password in `secrets/argocd.env`.

---

## 11. Step 8 — The GitOps repository + first applications

```bash
./gitlab/scripts/50-gitops-repository.sh
```

Pushes the REAL `gitops-repository/` content into GitLab: the
`microservice-standard` Helm chart (v1.1.0), the **orders-api** sample app
(rendered base + dev/qa/uat/prod overlays, canary Rollout enabled), and
`clusters/` (ArgoCD AppProjects + ApplicationSets). ArgoCD's root app
cascades: **root → projects → ApplicationSets → one Application per
app-per-environment** — all within ~3 minutes of this push.

✅ **Checkpoint 11:** ArgoCD UI shows `orders-api-dev` as **Synced** with
health **Progressing** — deployed with zero `kubectl apply` from you. The
seed pods are DENIED by Kyverno (`require-digest-pinning`): the placeholder
image `registry.devsecops.internal@sha256:0000…` is neither on the platform
registry nor signed — the supply-chain policy working as designed. The
FIRST REAL BUILD (Step 11/§14) pushes a signed, digest-pinned image via
`updateGitOps` and flips the app to **Healthy**. Click in: the resource
tree (Rollout, Service, PDB, NetworkPolicy, ExternalSecret — the
ExternalSecret shows Ready and its `db-creds` Secret exists in the
namespace, proving the Vault→ESO chain end-to-end). Ground truth:

```bash
kubectl get rollout,pods -n orders-api-dev
kubectl get rollout orders-api -n orders-api-dev -o jsonpath='{.spec.template.spec.containers[*].image}'
#   → ends in @sha256:0000… (the seed placeholder — pods stay denied by
#     Kyverno until the FIRST REAL BUILD replaces it with a genuine signed
#     digest in Step 11; `kubectl get pods` shows none meanwhile)
```

---

## 12. Step 9 — Monitoring + notifications

```bash
./monitoring/scripts/10-enable-nexus-metrics.sh     # Nexus scrape target (zero-priv 'metrics' user)

# Optional but recommended: fill SMTP_HOST/SLACK_WEBHOOK_URL/TEAMS_WEBHOOK_URL
# + mailboxes in .env NOW (empty = channel stays disabled, safely):
./monitoring/scripts/20-configure-notifications.sh  # wires Alertmanager + Jenkins creds + flags
docker compose --profile core up -d --force-recreate jenkins   # JCasC picks up webhook creds (env_file needs recreate)
```

**Prove the alerting path end-to-end:**

```bash
docker compose exec alertmanager wget -qO- http://localhost:9093/api/v2/alerts \
  | jq 'map(.labels.alertname) | unique'          # ✅ contains "Watchdog" (heartbeat)
docker compose exec alertmanager wget -qO- --header='Content-Type: application/json' \
  --post-data='[{"labels":{"alertname":"SetupTest","severity":"warning"},"annotations":{"summary":"Platform setup complete"}}]' \
  http://localhost:9093/api/v2/alerts             # ✅ arrives in Slack/email if configured
```

Grafana (`https://grafana.<domain>`) → Dashboards → **DevSecOps** folder:
Platform Overview (SLOs), CI/CD Pipeline, Infrastructure, Security & Vault,
Platform Logs.

---

## 13. Step 10 — Backups

```bash
./scripts/backup-now.sh        # native dumps (vault raft, gitlab, sonar pg, nexus) + restic snapshot + integrity check
./scripts/restore.sh list      # ✅ your first snapshot is listed
```

Schedule it (the `backup` service additionally runs a restic-only loop every
`BACKUP_INTERVAL_HOURS`):

```bash
echo '0 2 * * * root cd /path/to/devsecops-platform && ./scripts/backup-now.sh >> /var/log/devsecops-backup.log 2>&1' \
  | sudo tee /etc/cron.d/devsecops-backups
```

**For anything real:** set `RESTIC_REPOSITORY=sftp:backup@backup.internal:/srv/restic/devsecops`
(or rest:/s3:) in `.env` — a local repo survives mistakes, not host loss.
Full DR procedures: `backup-recovery.md`.

---

## 14. Step 11 — Your first end-to-end deployment 🎉

Seed the sample service **one time** (idempotent). This creates
`teams/orders/orders-api` in GitLab, pushes the stdlib-Python sample app +
standard Jenkinsfile, and repoints `applications/orders-api` in the LIVE
gitops-repository from the `registry.devsecops.internal` seed placeholder to
`registry.<domain>` — required because `pinDigest` matches `images[].name`
against the built image and Kyverno only pins/verifies `registry.<domain>/*@sha256:*`:

```bash
./gitlab/scripts/45-seed-orders-api.sh
```

```bash
# 1. trigger discovery + the first build (pick ONE):
#    a) Jenkins UI → teams → orders → "Scan Multibranch Pipeline Now"
#       (first discovery of main auto-starts the build)
#    b) or make a trivial change and let the webhook/hourly scan fire:
#       browser: GitLab → teams/orders/orders-api → README.md → Edit →
#                append a line → Commit to main   (no local git needed)
#       terminal: git clone https://gitlab.<domain>/teams/orders/orders-api.git
#                 && cd orders-api && echo "# touched $(date)" >> README.md
#                 && git commit -am "first platform run" && git push

# 2. watch Jenkins
#    https://jenkins.<domain> → teams → orders → orders-api → main → Console
```

**What you should see, stage by stage** (~8–15 min first run; caches are cold):

| Stage | Look for |
|---|---|
| Detect/Checkout | language detected from repo markers |
| Secrets scan | gitleaks verdict (clean) |
| Build + Unit tests | toolchain on the matching agent; JUnit results archived |
| Quality gate | Sonar analysis + WAIT for verdict |
| SAST + deps | semgrep (offline rules) + trivy-fs/OWASP-DC merged verdict |
| Container build | BuildKit → **the digest** `sha256:…` (write it down!) |
| Image scan → SBOM → sign | trivy by-digest; SBOM to Nexus raw-hosted; cosign signature |
| Publish | image in Nexus docker-hosted |
| GitOps update | the `chore(gitops): orders-api@dev → sha256:…` commit in the gitops repo |
| Sync | ArgoCD syncs `orders-api-dev`; watch the app turn Synced+Healthy |
| Verify | convergence + "pods run exactly your digest" + no crash-loops |
| Post-deploy | smoke tests (or the loud SKIPPED-NO-TESTS report) |
| Notify | Slack/email with service, digest, environment, verdict |

**The evidence tour (do this once — it's the "understand" shortcut):**
find the SAME digest in all five places: ① Jenkins build log, ② Nexus
docker-hosted image, ③ the gitops overlay commit (`images: … digest:`),
④ `kubectl get pods -n orders-api-dev -o jsonpath=…` (live pods), ⑤
`reports/verify-*.json` in the build artifacts. One fingerprint, five
independent systems — that's the trust chain.

✅ **Checkpoint 14:** build green, canary rollout completed
(`kubectl get rollout orders-api -n orders-api-dev`), notification received.

⚠️ **If a gate blocks you:** that's the platform WORKING. Read the stage log +
`reports/` artifact; the message names the tool, rule, and threshold.
Policy knobs live in `jenkins/shared-library/config/platform-config.yaml`
(and per-repo `.devsecops.yaml` overrides — see `examples/`).

---

## 15. Day-2 operations (the tasks you'll actually repeat)

### 15.1 Lifecycle

```bash
docker compose ps                                  # state of the world
docker compose logs -f --tail=100 jenkins          # any service's logs
docker compose --profile all up -d                 # start everything
docker compose stop / start                        # pause/resume (state kept)
./scripts/health-check.sh                          # verdict
```

**After any Vault or host restart:** unseal Vault (§6.1) — everything else
self-heals. ArgoCD re-syncs the cluster automatically.

### 15.2 Onboard a NEW microservice (the real workflow)

1. **Create the repo** in GitLab under your team group (Settings → visible to
   Jenkins' branch source; register the webhook with
   `gitlab/scripts/add-webhook.sh <project-path>`).
2. **Add two files** (copy from `jenkins/shared-library/examples/`):
   - `Jenkinsfile`: `@Library('devsecops-shared-library') _` + `microservicePipeline()`
   - optional `.devsecops.yaml` (tighten policy; never loosen)
   - a `Dockerfile` for your service
3. **Create its GitOps app**: copy `gitops-repository/applications/orders-api/`
   → `applications/<your-svc>/`, edit `values.yaml` (image name, port,
   resources, `rollout.enabled`), re-render:
   `gitops-repository/scripts/render-app.sh <your-svc>`, commit, push.
   The ApplicationSet creates the per-env Applications automatically.
4. **Seed its Vault secret** (if it needs one):
   `vault kv put secret/apps/<your-svc>/<name> key=value` matching the
   ExternalSecret template in the chart values.
5. Push code → the pipeline does the rest.

### 15.3 Promote dev → qa → uat → prod

Jenkins → **`platform/gitops-promotion`** job → parameters: service, target
environment, (digest auto-detected from the source env; override allowed).
It re-pins the SAME digest into the target overlay, commits, syncs, and waits.
Prod additionally expects an approval per your Jenkins matrix
(`release-manager` role).

### 15.4 Manual rollback

```
Jenkins → platform/gitops-promotion → target env + explicit DIGEST of the
previous good version            (or scripted:)
rollbackDeployment(service: 'orders-api', env: 'prod', reason: 'incident-42',
                   digest: 'sha256:…')
```

Automatic rollbacks need no action — they appear as `revert(gitops): …`
commits and a `rollback_executed` notification.

### 15.5 Upgrades (the safe pattern)

1. `./scripts/backup-now.sh` 2. change ONE version pin in `.env`
3. `docker compose pull <svc> && docker compose up -d <svc>`
4. `./scripts/health-check.sh` + read that component's release notes.
Never upgrade GitLab more than one minor at a time; never unpinned.

### 15.6 Security exceptions (findings you accept, formally)

Add an entry to `security/exceptions/` (template:
`jenkins/shared-library/examples/security-exceptions.yaml`): rule/CVE id,
owner, ticket, justification, approver, **expiry date**. Expired =
auto-reblocks. Review the register monthly.

---

## 16. Understanding the platform (the mental models)

### 16.1 The three loops

```
BUILD LOOP (minutes)   push → Jenkins 20 stages → signed digest → gitops commit
DELIVERY LOOP (seconds) ArgoCD polls gitops repo → cluster matches git → verify
FEEDBACK LOOP (always)  metrics/logs → rules → Alertmanager → humans
                        (+ Watchdog proving the loop itself is alive)
```

Every incident question maps to a loop: "why did my build fail?" (build),
"why is prod different from git?" (delivery — it can't be, drift is healed),
"why did nobody notice?" (feedback).

### 16.2 Who is allowed to do what (follow the credentials)

| Actor | Powers | Where defined |
|---|---|---|
| `jenkins-ci` (GitLab PAT) | clone code, push commit statuses | gitlab/scripts/20 |
| `gitops-write` token | push to gitops-repository ONLY | gitlab/scripts/50 |
| `jenkins-cd` (ArgoCD) | get/sync applications, scoped projects | kubernetes/argocd/ |
| verifier SA (kubeconfig) | READ cluster + pods/portforward | kubernetes/scripts/20 |
| ESO SA (in-cluster) | Vault: read `secret/apps/*` only | vault/policies/eso-app-secrets.hcl |
| Jenkins AppRole | Vault: read `secret/platform/*` only, 1h tokens | vault/policies/jenkins-platform.hcl |
| Kyverno (cluster) | refuses unsigned/mutable-tag images | kubernetes/kyverno/policies/ |
| humans | 6 Jenkins roles + GitLab roles (+ LDAP/OIDC kits) | jenkins/casc/10-security.yaml |

Notice the pattern: **no single identity can both build AND deploy AND read
app secrets**. Compromise any one → bounded blast radius.

### 16.3 "Where do I change X?" (the file map)

| Change… | Edit… | Apply with… |
|---|---|---|
| pipeline behavior/gates | `jenkins/shared-library/` | push to its GitLab repo (Jenkins reloads per build) |
| platform defaults (flags, thresholds, envs) | `…/config/platform-config.yaml` | same push |
| Jenkins system config/credentials | `jenkins/casc/*.yaml` + `secrets/*.env` | `docker compose --profile core up -d --force-recreate jenkins` (env_file is read at CREATE only) |
| agent tooling | `jenkins/agents/<x>/Dockerfile` | `./scripts/build-images.sh --agent <x>` + recreate |
| deployment shape (all services) | `gitops-repository/helm-charts/microservice-standard/` | render-app.sh + commit |
| one env of one service | `gitops-repository/applications/<svc>/overlays/<env>/` | commit (ArgoCD syncs) |
| cluster admission rules | `kubernetes/kyverno/policies/` | re-run bootstrap (idempotent) |
| alerts / SLO objectives | `monitoring/prometheus/rules/*.yml` | `docker compose exec prometheus kill -HUP 1` |
| log alerts | `monitoring/loki/rules/fake/*.yml` | `docker compose restart loki` |
| dashboards | `monitoring/grafana/dashboards/*.json` | automatic (≤60 s) |
| routing/TLS | `reverse-proxy/configuration/*.tmpl|yml` | bootstrap.sh + restart traefik |
| notification endpoints | `.env` | `monitoring/scripts/20-configure-notifications.sh` |
| backup scope/cadence | `.env` + cron | `backup-recovery.md` §3/§7 |

### 16.4 The digest trust chain (the platform's thesis, one picture)

```
 source ──build──▶ image@sha256:abc ──scan──▶ sbom ──sign──▶ signature(abc)
                                     │
              git commit pins abc ───┘──▶ ArgoCD applies ──▶ Kyverno admits
                                                              ONLY signed abc
                                                     ──▶ verify: running pods == abc
                                                     ──▶ rollback: re-pin previous abc'
```

Tags lie; digests don't; signatures prove origin; git records every hop.

---

## 17. Troubleshooting matrix

**First five commands, always:**

```bash
docker compose ps --format "table {{.Name}}\t{{.Status}}"
docker compose logs --tail=100 <service>
./scripts/health-check.sh
kubectl get pods -A | grep -v Running
kubectl get events -A --sort-by=.lastTimestamp | tail -20
```

Then Grafana → Platform Overview (what's down/burning) → Platform Logs
(`{service="<suspect>"} |= "error"`).

| Symptom | Likely cause → fix |
|---|---|
| GitLab never healthy | not enough RAM (`free -g`; needs ~4 GB) → raise limit or stop other services |
| Jenkins job never triggers | webhook missing → `gitlab/scripts/add-webhook.sh`; or branch source not scanned → scan now |
| Build fails "SET_IN_PHASE_N" | that phase's script wasn't run → the error names it |
| Build fails at image push (401) | nexus-deploy creds stale → re-run `nexus/scripts/run-all.sh` + recreate jenkins |
| Semgrep/DC stage extremely slow | NVD mirror not built → §8.4 (+ API key) |
| ArgoCD app OutOfSync forever | base/manifests drifted from chart → re-run `render-app.sh` + commit |
| Pods refused, policyreport shows violations | unsigned image or mutable tag → must come through the pipeline (that's the point) |
| ExternalSecret not Ready | Vault sealed? path missing? → `vault status`; `vault kv get secret/apps/<svc>/<name>` |
| verify fails "Paused at timeout" | canary pause > `verify.timeoutSec` → bound pauses (gitops.md §9.4) |
| No notifications | script not run / placeholders active → §12; check build log for "Notify … skipped" |
| Alerts silent entirely | Watchdog missing → alerting path dead → observability.md §8 |
| Vault sealed after restart | normal → unseal with 3 keys (§9.1) |
| Loki/Grafana no logs | Alloy/socket-proxy down → `docker compose logs alloy` |
| Disk filling | `du -sh $DATA_ROOT/*`; retention knobs in `.env`; `docker system prune` (safe: images are in Nexus) |

Deeper: `documentation/troubleshooting tables live in each domain doc`
(installation §per-phase, gitops §8, observability §8, backup-recovery,
security). When stuck: paste logs into your AI assistant with the question
"diagnose step by step, smallest fix first."

---

## 18. Quick reference

### 18.1 Every URL

`https://<service>.<PLATFORM_DOMAIN>` for: gitlab, jenkins, sonar, nexus,
vault, grafana, prometheus, alertmanager, registry (Nexus docker-group),
traefik, argocd. Plus: ArgoCD NodePort `https://<node-ip>:30443`, Jenkins
agent JNLP port 50000, GitLab SSH `${GITLAB_SSH_PORT}`.

### 18.2 Every credential

| What | Where |
|---|---|
| all generated passwords/tokens | `secrets/*.env` (0600, gitignored) |
| Vault unseal keys + root token | YOUR off-host custody (+ `secrets/vault-root.env` for scripts) |
| ArgoCD admin | `secrets/argocd.env` |
| read-only kubeconfig | `secrets/k8s.env` (base64) |
| Grafana/Prometheus basic-auth | `secrets/grafana.env` / `secrets/monitoring.env` |

### 18.3 Command cheat-sheet

```bash
./scripts/bootstrap.sh                 # (re)generate secrets/CA/config — always safe
./scripts/build-images.sh [--agent X]  # (re)build custom images
docker compose --profile all up -d     # everything up
./scripts/health-check.sh              # verdict
./scripts/validate.sh                  # static repo validation
./scripts/backup-now.sh                # full backup on demand
./scripts/restore.sh {list|files|vault-raft|gitlab|sonar-db|all}
./scripts/cleanup.sh                   # TEAR DOWN (asks; --volumes destroys data)
gitlab/scripts/run-all.sh              # GitLab provisioning (idempotent)
kubernetes/scripts/00-bootstrap-cluster.sh   # cluster tooling (idempotent)
monitoring/scripts/20-configure-notifications.sh
kubectl get rollout,pods,events -n <app>-<env>
docker compose exec prometheus kill -HUP 1   # reload prometheus config
docker compose exec vault vault status
```

### 18.4 Reading order for understanding (after it runs)

1. this guide §16 (mental models) — 20 min
2. `LEARNING-GUIDE.md` Days 2–3 theory (pipeline + GitOps deep) — 2 h
3. `architecture.md` decisions D-01…D-38 — skim now, re-read monthly
4. the domain doc when you touch that domain (pipeline / gitops / security /
   observability / backup-recovery / performance)

---

**You now have a running, secured, observable, backed-up software factory.**
The platform enforces one promise at every hop: *what you scanned and signed
is exactly what runs, every change is a git event, and failures roll
themselves back.* Everything else is detail — and the detail is all in
`documentation/`.
