# 🎓 The DevSecOps Platform — 4-Day Learning Bootcamp

> **Who this is for:** you are technical (you can code, use git, run Linux
> commands) but NEW to DevOps and CI/CD. This guide turns the entire platform
> in this repository into a **4-day practical course**. Every day: theory in
> the morning, hands-on in the afternoon, exercises + a quiz to lock it in.
>
> **The promise:** by the end of Day 4 you will have *built, broken, watched,
> and restored* a full enterprise DevSecOps platform — and you will understand
> every layer of it, not just memorized commands.
>
> **How AI helps you:** at the end of every section there is an
> *"🤖 Ask your AI assistant"* box with ready-made prompts. Copy them into
> this chat (or any AI) whenever you get stuck, want a deeper explanation,
> or want to check your understanding. You are not alone in this journey.

---

## 📋 How to use this guide

| | |
|---|---|
| **Total time** | 4 days × ~7–8 hours (can be split into 8 half-days) |
| **You need** | A Linux machine/VM: **8+ CPU cores, 32 GB RAM, 80 GB free SSD** (lab tier), Docker Engine + compose plugin, internet access, a domain name or `.local` domain you control DNS/hosts for |
| **Prior skills** | Basic git, basic Linux terminal, any programming language |
| **Format per day** | 🎯 Goals → 📖 Theory → 🛠️ Hands-on (with ✅ checkpoints) → 🏋️ Exercises → 📝 Quiz → 🤖 AI prompts |
| **Golden rule** | Every "magic" behavior here is a FILE in this repo. When something surprises you, open the file that does it and read. This habit is the real skill. |

**The 4 days at a glance:**

```
DAY 1 — Foundations + the Control Plane    (what/why + Docker stack alive + every UI)
DAY 2 — The CI Pipeline + Security Gates   (anatomy of the 20 stages + break things safely)
DAY 3 — GitOps + Kubernetes + Delivery     (cluster, ArgoCD, canary, verify, auto-rollback)
DAY 4 — Observability + DR + Capstone      (dashboards, alerts, SLOs, backups, onboard YOUR service)
```

**If you only have a small laptop (16 GB):** you can still do Days 1–2 theory
+ a reduced stack (`--profile core` without monitoring), and Days 3–4 on a
rented cloud VM for a few hours. The exercises mark which need the full stack.

---

# 🧭 ORIENTATION — The platform in one picture (read before Day 1, 15 min)

Software teams that deploy manually live with fear: nobody knows what is
running where, releases are big risky events, security is an afterthought,
and recovery means "find Dave's zip file." This platform automates the entire
journey from `git push` to verified production deployment — with security
gates, signatures, SLOs, and automatic rollback built in.

It has **two worlds**:

```
WORLD 1 — CONTROL PLANE (one Docker host, docker-compose)         [Days 1–2]
┌──────────────────────────────────────────────────────────────────────┐
│ GitLab     code storage + webhooks ("someone pushed!")               │
│ Jenkins    the pipeline BRAIN — runs the 20-stage pipeline           │
│ Agents     worker containers (python/java/node/security/general)     │
│ SonarQube  code quality analysis        Nexus  artifacts + registry  │
│ Vault      the secrets bank             Traefik  the HTTPS front door│
│ Prometheus·Grafana·Loki·Alloy·Alertmanager   the nervous system      │
└──────────────────────────────────────────────────────────────────────┘
            │ signs+pushes images, then COMMITS a digest ↓
WORLD 2 — DEPLOYMENT PLANE (Kubernetes; K3s in the lab)            [Day 3]
┌──────────────────────────────────────────────────────────────────────┐
│ gitops-repository   Helm chart + per-env overlays (THE ONLY DOOR)    │
│ ArgoCD              watches the repo, makes the cluster match it     │
│ Argo Rollouts       canary / blue-green releases                     │
│ Kyverno             bouncer: unsigned or mutable-tag image? REFUSED  │
│ ESO                 fetches app secrets from Vault at deploy time    │
│ your microservices  run in dev / qa / uat / prod namespaces          │
└──────────────────────────────────────────────────────────────────────┘
```

Three ideas everything hangs on (you'll meet each one in depth on its day):

1. **CI/CD** — every push runs an automatic pipeline: build → test → scan →
   package → deploy. Small, frequent, verified changes beat big rare ones. *(Day 2)*
2. **DevSecOps** — security runs INSIDE every pipeline (secret scans, SAST,
   dependency CVEs, image scans, signing). Vulnerable changes are blocked at
   the factory, not found after an incident. *(Day 2)*
3. **GitOps** — the only way to change production is a git commit. ArgoCD
   makes the cluster match the repo; rollback = revert a commit; the git log
   IS your deployment history. *(Day 3)*

🤖 **Ask your AI assistant:**
- "Explain CI/CD to me using a restaurant kitchen analogy, then map each kitchen role to a tool in a DevOps platform."
- "Why would a company run its CI tooling on Docker Compose but its applications on Kubernetes? Give me 3 pros and 2 cons."

---

# 📅 DAY 1 — Foundations + Bringing the Control Plane to Life

## 🎯 Goals

By tonight you will be able to:
1. Explain what every control-plane component does and WHY it exists.
2. Read a `docker-compose.yml` and understand networks, profiles, healthchecks, secrets.
3. Have the whole stack RUNNING on your machine.
4. Log into every UI (GitLab, Jenkins, SonarQube, Nexus, Grafana, Traefik) and find where each credential came from.
5. Explain the concepts: idempotency, pinned versions, internal CA/TLS, profiles.

## 📖 Theory block 1.1 — Docker Compose as a platform runtime (45 min)

You know containers run one process in an isolated filesystem. **Compose**
declares a whole *society* of containers in one YAML:

- **services** — each container: its pinned image (`gitlab/gitlab-ce:19.5.1-ce.0`
  — a version frozen on purpose; "latest" is banned on this platform), its
  volumes (persistent data), networks, resource limits, healthcheck.
- **networks** — private virtual wires. This platform has 8 (`frontend`,
  `scm`, `cicd`, `artifact`, `security`, `monitoring`, `management`, `agents`).
  Services only talk to whom they share a wire with. Example: build agents sit
  on `agents-network` and can reach GitLab + Nexus — but NOT Vault or the
  databases. That's *segmentation as architecture*, not as paperwork.
- **profiles** — service groups you start selectively: `core` (the factory),
  `monitoring` (the nervous system), `agents` (workers), `backup`, `build`.
  Lets a 16 GB laptop run a subset.
- **healthchecks** — each service proves it's alive (`wget localhost/api/health`).
  Compose can wait for "healthy" before starting dependents — boot ORDER without
  fragile sleep-scripts.
- **hardening defaults** — every service inherits an anchor (`<<: *hardened`):
  `no-new-privileges`, dropped capabilities, read-only roots where possible.
  Read the top of `docker-compose.yml` — the anchors ARE the security policy.

**Why compose for the control plane?** These 14 services are long-lived
pets, not cattle: one GitLab, one Jenkins. Compose gives pinning, healthchecks
and TLS on ONE box with zero cluster overhead. The *products* go to Kubernetes,
where self-healing and scaling matter.

📂 **Read now (30 min):** open `docker-compose.yml`. Find: the 8 network
definitions; the `*hardened` anchor; the `gitlab` service (note
`GITLAB_OMNIBUS_CONFIG` — GitLab's entire config injected as env); the
`jenkins` service (note the SEVEN `env_file` entries — each is a credential
contract from a different phase); `prometheus` (note the `secrets` mount).

🤖 **Ask your AI assistant:**
- "In docker-compose, what's the difference between `depends_on` and `depends_on` with `condition: service_healthy`? Why does the second one matter for a stack like GitLab+Jenkins?"
- "Explain Docker network segmentation as a security control. Quiz me with 3 scenarios where two containers should NOT share a network."

## 📖 Theory block 1.2 — Secrets, TLS, and "the bootstrap contract" (30 min)

Two rules this platform never breaks:

1. **No secret ever lives in git.** All secret material lives in `secrets/`
   (mode 0600, gitignored) or Vault. `scripts/bootstrap.sh` GENERATES every
   initial secret (admin passwords, DB passwords, webhook tokens, an internal
   Certificate Authority + wildcard TLS cert) *idempotently* — it never
   overwrites an existing secret, so re-running is always safe.
   "**Idempotent**" = run once or ten times, same end state. Every script in
   this repo is idempotent; you'll rely on that constantly.

2. **Fail-closed placeholders.** Where a secret can't exist yet (e.g. a GitLab
   token before GitLab first boots), the file contains `SET_IN_PHASE_N`. Any
   pipeline step that touches such a placeholder FAILS LOUDLY with the exact
   fix command — instead of silently doing nothing. Search the repo for
   `SET_IN_PHASE` to see the pattern.

**TLS:** Traefik terminates HTTPS for every UI (`gitlab.<domain>`,
`jenkins.<domain>`, …) using a wildcard cert signed by the internal CA that
bootstrap creates. Your browser won't trust that CA at first — you'll import
`reverse-proxy/certificates/ca.crt` (exercise 1.4).

🤖 **Ask your AI assistant:**
- "What does 'fail-closed' mean in security engineering? Give me 3 examples of fail-closed vs fail-open behavior in CI/CD systems."
- "Explain what a Certificate Authority is like I'm a developer who has only ever used Let's Encrypt."

## 🛠️ Hands-on 1.3 — Bring the stack up (2.5–3 h)

> Every step has a ✅ checkpoint. Do not proceed past a failed checkpoint —
> debug it (that IS the learning). The 🤖 boxes are your debug companions.

**Step 0 — prerequisites**

```bash
docker --version && docker compose version     # both installed
nproc && free -g && df -h /var/lib/docker      # cores / RAM / disk
echo "127.0.0.1 gitlab.devops.local jenkins.devops.local sonar.devops.local \
nexus.devops.local vault.devops.local grafana.devops.local prometheus.devops.local \
alertmanager.devops.local registry.devops.local traefik.devops.local" | sudo tee -a /etc/hosts
```
(Use YOUR domain instead of `devops.local` — with real DNS if you have it.)

✅ **Checkpoint:** `docker run --rm hello-world` prints success.

**Step 1 — configure**

```bash
cd devsecops-platform
cp .env.example .env
nano .env      # PLATFORM_DOMAIN=devops.local · DATA_ROOT=/mnt/data/devsecops (SSD!)
mkdir -p "$DATA_ROOT" 2>/dev/null || sudo mkdir -p /mnt/data/devsecops && sudo chown $USER /mnt/data/devsecops
```

Read `.env.example` top to bottom as you edit — every variable is commented.
Notice the three groups: versions (all pinned), sizing (CPU/mem limits),
credentials/endpoints (filled by scripts later).

**Step 2 — bootstrap (secrets + CA + rendered configs)**

```bash
./scripts/bootstrap.sh
```

What just happened internally (open the script and find each part):
- created `DATA_ROOT` directories,
- generated ~10 secret files in `secrets/` (look: `ls -la secrets/` — mode 600),
- created an internal CA + wildcard cert in `reverse-proxy/certificates/`,
- rendered `dynamic.yml.tmpl` → Traefik's live routing config.

✅ **Checkpoint:** `ls -l secrets/ | awk '{print $1}' | sort -u` shows only
`-rw-------` and `-rwx------` style permissions (no world-readable secret).

**Step 3 — build the custom images**

```bash
./scripts/build-images.sh            # jenkins controller + 7 agents; 15–30 min first time
docker images | grep devsecops
```

While it builds, READ `jenkins/Dockerfile` (Jenkins + 29 *pinned* plugins —
find `plugins.txt`) and ONE agent, e.g. `jenkins/agents/general/Dockerfile`
(the Swiss-army worker: git, kubectl, helm, kustomize, k6, newman, cosign…).
Notice every tool has an ARG'd version verified against a real download URL.

✅ **Checkpoint:** `docker images` lists the controller + agent images.

**Step 4 — start the world**

```bash
docker compose --profile core up -d          # ~10 min (GitLab is slow on first boot)
docker compose --profile monitoring up -d
docker compose --profile agents up -d
docker compose --profile backup up -d
watch -n5 'docker compose ps --format "table {{.Name}}\t{{.Status}}"'   # wait for (healthy)
./scripts/health-check.sh
```

✅ **Checkpoint:** `health-check.sh` reports all services healthy. If GitLab
is still `health: starting` after 10 min: `docker compose logs gitlab | tail -50`.

**Step 5 — first logins (the credential treasure hunt)**

For each UI, DON'T look up the password in a doc — *hunt it down* in
`secrets/`. This teaches the whole credential model in 10 minutes:

| UI | URL | Credential lives in |
|---|---|---|
| GitLab | `https://gitlab.<domain>` | user `root`, password `GITLAB_ROOT_PASSWORD` in `secrets/gitlab.env` |
| Jenkins | `https://jenkins.<domain>` | `JENKINS_ADMIN_USER/PASSWORD` in `secrets/jenkins.env` |
| Nexus | `https://nexus.<domain>` | `admin` / `NEXUS_ADMIN_PASSWORD` in `secrets/nexus.env` (written by its script — until then use the initial admin password file inside the container: `docker compose exec nexus cat /nexus-data/admin.password` — first-login rotates it via `sonarqube|nexus/scripts/10-*`) |
| SonarQube | `https://sonar.<domain>` | admin/admin → the script rotates it |
| Grafana | `https://grafana.<domain>` | `secrets/grafana.env` |
| Traefik dashboard | `https://traefik.<domain>/dashboard/` | basic-auth from `secrets/monitoring.env` |

✅ **Checkpoint:** you are logged into all six, and you can say for each:
"this password was generated by bootstrap / will be rotated by script X."

**Step 6 — run the GitLab + Sonar + Nexus automation (the platforms configure themselves)**

```bash
./gitlab/scripts/run-all.sh        # root token, groups, service users, projects, protected branches, seed repos
./sonarqube/scripts/run-all.sh     # admin rotation, quality gates, CI token
./nexus/scripts/run-all.sh         # admin rotation, 17 repos, cleanup policies, jenkins-ci account
./security/scripts/10-cosign-keys.sh   # image-signing keypair → secrets/cosign/
```

✅ **Checkpoint:** GitLab shows the `platform/` group with seeded projects;
Nexus → Repositories lists ~17; Sonar → Quality Gates shows `devsecops-default`.

🤖 **Ask your AI assistant (debug companion — use ALL day):**
- "Here is my `docker compose ps` output and the failing service's logs: <paste>. Diagnose step by step and tell me the smallest fix."
- "My bootstrap.sh failed halfway. Is it safe to re-run? Explain idempotency in this context."
- "Explain what a GitLab Personal Access Token is vs a password, and why CI uses tokens."

## 🏋️ Day-1 exercises (pick ≥3)

1. **Trace a request.** `curl -kv https://jenkins.<domain> 2>&1 | head -30`.
   Find: which cert was served, who issued it (your internal CA), and then in
   `reverse-proxy/configuration/dynamic.yml.tmpl` find the router rule +
   middleware chain that handled it. *Concept: reverse proxy routing.*
2. **Prove segmentation.** `docker compose exec agent-general getent hosts vault`
   → fails or resolves but `curl http://vault:8200/v1/sys/health` should NOT
   connect (no shared network). Then from `jenkins`: it SHOULD work. Explain
   the difference using the `networks:` blocks in compose. *Concept: network
   policy by topology.*
3. **Healthcheck anatomy.** Pick 3 services; read their `healthcheck:` block;
   run the exact test command inside the container yourself
   (`docker compose exec prometheus wget -qO- http://localhost:9090/-/healthy`).
4. **Trust the CA.** Import `reverse-proxy/certificates/ca.crt` into your
   browser/OS trust store; reload the UIs — padlock icons appear. *Concept: PKI.*
5. **Break and restore.** `docker compose stop nexus` → watch Grafana's
   Platform Overview (Day 4 preview: the target goes DOWN and a TargetDown
   alert appears in Alertmanager after 5 min) → `docker compose start nexus`.
6. **Version archaeology.** Pick 5 images in `.env.example`; for each, find in
   the repo WHERE that version string is used and what would break if you
   bumped it carelessly. *Concept: pinning as a supply-chain control.*

## 📝 Day-1 quiz (answers below — no peeking)

1. Why is `gitlab-ce:19.5.1-ce.0` pinned instead of `latest`?
2. What is the difference between `secrets/` files and Vault? When does each get used?
3. Your script fails with "credential is still the placeholder SET_IN_PHASE_4". What is the design philosophy behind this error, in one sentence?
4. Name the network that gives build agents access to Nexus and explain why agents are NOT on the monitoring network.
5. What does `depends_on: condition: service_healthy` protect you from? Give the GitLab→Jenkins example.
6. Why does bootstrap generate an internal CA instead of using Let's Encrypt by default?

<details><summary>Answers</summary>

1. Reproducibility + supply-chain safety: a rebuild months from now must produce
   the same platform; "latest" silently changes behavior and can break plugin
   compatibility (Jenkins especially).
2. `secrets/` = bootstrappable, file-based, 0600 material that must exist BEFORE
   anything can talk to anything (JCasC reads env at Jenkins start). Vault =
   runtime secret bank with policies/audit/leases for application + platform
   secrets. Files are the cold-start fallback; Vault is the source of truth once seeded.
3. Fail-closed: a missing integration must surface as a loud, actionable error —
   never as a silent no-op that everybody assumes worked.
4. `agents-network` (shared with GitLab/Nexus). Agents don't need metrics access;
   Prometheus pulls FROM targets on `monitoring-network` — agents being absent
   limits lateral movement if a build container is compromised.
5. Startup-race failures: Jenkins querying GitLab (or Prometheus scraping Loki)
   before the dependency finished initializing → crash loops or empty data.
   `service_healthy` waits for the dependency's own healthcheck to pass.
6. A lab/offline host has no public DNS/HTTP-01 challenge path; the internal CA
   gives full HTTPS (and teaches PKI). `TLS_MODE=letsencrypt` exists for public sites.
</details>

---

# 📅 DAY 2 — The CI Pipeline: Anatomy, Security Gates, and Breaking Things Safely

## 🎯 Goals

By tonight you will be able to:
1. Explain the difference between a Jenkinsfile and a shared library — and why enterprises use libraries.
2. Recite the 20-stage pipeline from memory (roughly) and the *reason* for each gate.
3. Trigger a real build and read its stages, logs, reports, and notifications like a pro.
4. Explain image digests, SBOMs, and cosign signatures — the trust chain.
5. Deliberately break builds 4 different ways and know exactly where each stops.

## 📖 Theory block 2.1 — Jenkins: jobs, agents, and the library pattern (45 min)

**Controller vs agents.** The Jenkins *controller* (the UI + scheduler) runs
ZERO builds — it has no executors. Every build runs inside an *agent*
container (built yesterday from `jenkins/agents/*/Dockerfile`). Why? A build
should never be able to touch the controller's credentials or config, a
poisoned build can't persist on the controller, and agents are disposable
(warm pool + on-demand via the Docker cloud).

**Multibranch + webhooks.** GitLab tells Jenkins "branch X was pushed" via
webhook (secured with a shared secret header). Jenkins' GitLab Branch Source
auto-creates a job per branch/MR. You never "create a Jenkins job" by hand —
the repo IS the job.

**The shared library pattern — the most important idea today.** Instead of
every team writing 300 lines of pipeline YAML/Groovy (which drifts, gets
copy-pasted wrong, and can't be centrally secured), the platform ships the
pipeline ONCE as a library (`jenkins/shared-library/`). A team's entire
Jenkinsfile:

```groovy
@Library('devsecops-shared-library') _
microservicePipeline()
```

That one call expands to all 20 stages. The library lives in GitLab
(published yesterday-ish, see Hands-on), is versioned (`main`), and is
*implicitly* loaded (JCasC config in `jenkins/casc/50-unclassified.yaml`).

**Explore the library now (45 min, guided):**

```
jenkins/shared-library/
├── vars/                      ← the "steps" (global variables = callable steps)
│   ├── microservicePipeline.groovy   ← START HERE: the orchestrator
│   ├── detectProject.groovy          ← language/monorepo detection
│   ├── runUnitTests / runSAST / scanSecrets / runDependencyScan / …
│   ├── buildContainer / scanContainer / generateSBOM / signImage
│   ├── updateGitOps / deployApplication / promoteDigest      (Day 3)
│   └── verifyDeployment / runPostDeploy / rollbackDeployment (Day 3)
├── src/org/company/devsecops/ ← supporting classes (not steps)
│   ├── PlatformConfig.groovy  ← loads platform-config.yaml, merges per-repo overrides
│   ├── SecurityGate.groovy    ← the policy engine: thresholds + the exception register
│   ├── FindingGate/RegistryAuth/PipelineLogger/GitOpsRepo/KubeAccess/NotificationService…
└── config/platform-config.yaml ← THE platform brain: stage flags, envs,
                                  security thresholds, gitops/verify/notify settings
```

Open `microservicePipeline.groovy` and find the `stages { … }` block — read it
like a table of contents. Notice each stage's `when { stageFlagEnabled('…') }`
— flags live in `platform-config.yaml` (all ON). A team can *tighten* (never
loosen) policy with a `.devsecops.yaml` in its repo — find the merge logic in
`PlatformConfig.groovy`.

🤖 **Ask your AI assistant:**
- "Compare Jenkins shared libraries vs one big Jenkinsfile vs per-team templates. Give me the maintenance and security trade-offs of each."
- "Open-question drill: quiz me on Jenkins controller/agent separation with 3 attack scenarios and ask me which layer stops each."

## 📖 Theory block 2.2 — The 20 stages, and the trust chain (60 min)

Read this twice; it's the spine of the whole platform. (Full detail per stage:
`documentation/pipeline.md`.)

```
 1 Discovery      which services changed (monorepo: git-diff scoped)
 2 Checkout       fetch code (jenkins-ci service user, least-privilege PAT)
 3 Pre-build secrets scan (Gitleaks)        ← STOP if secrets committed
 4 Build          language toolchain on the matching agent
 5 Unit tests     JUnit results archived; fail = stop
 6 Quality gate   SonarQube analysis + WAIT for verdict (bugs/coverage/smells)
 7 SAST           Semgrep, pinned offline rulesets (OWASP Top-10 …)
 8 Dependency scan  OWASP DC vs the NVD mirror (Log4Shell-class bugs)
 9 Container build BuildKit → image referenced BY DIGEST sha256:…
10 Image scan     Trivy scans the image BY DIGEST (OS pkgs + libs)
11 SBOM           Syft generates the ingredient list → published to Nexus
12 Sign           Cosign signs the digest; key lives in Vault
13 Publish        push to Nexus Docker registry (the ONLY registry)
14 Integration tests  (if the repo has them)
15 Confirm secrets scan (generated files too — belt & braces)
16 GitOps update  clone gitops-repo, re-render chart, PIN YOUR DIGEST into
                  the dev overlay, commit "chore(gitops): svc@dev → sha256:…"
17 Sync           ask ArgoCD (least-priv API account) to sync + wait healthy
18 Verify         READ-ONLY kubeconfig: pods converged? ready? running EXACTLY
                  the signed digest? no crash-loops? secrets synced?
19 Post-deploy    smoke tests (Newman/k6) against the LIVE service
20 Report/Notify  archive reports/**; Slack/Teams/email the verdict
        └─ (on 18/19 failure with autoRollback ON: re-pin the PREVIOUS digest
            from git history, commit revert(gitops): …, service recovers in
            seconds — and the build STILL FAILS)
```

**The security-policy engine.** Gates 3/6/7/8/10 are not hardcoded stop-lines;
they consult `SecurityGate` + `platform-config.yaml` thresholds. A finding can
be *exceptioned* via the exception register (`security/exceptions/*.yaml`):
owner, ticket, **expiry date** — expired exceptions re-block automatically.
Nobody edits the pipeline to skip a scan; that's the difference between a
policy and a suggestion.

**The trust chain — memorize this.** ONE fingerprint travels end-to-end:

```
build ──▶ image@sha256:abc ──▶ scanned@abc ──▶ signed@abc ──▶ git commit pins @abc
      ──▶ Kyverno admits only signed @abc ──▶ verify checks running pods == @abc
```

A mutable tag (`:latest`, `:1.2`) could be swapped between scan and run. A
digest cannot — it IS the content hash. "What you scanned is provably what
runs."

🤖 **Ask your AI assistant:**
- "Explain container image digests vs tags with a tamper scenario: how would an attacker exploit tags, and why does digest-pinning + signature verification stop them?"
- "What is an SBOM and why do regulations (EO 14028, EU CRA) care? Walk me through how I'd answer 'are we affected by CVE-2021-44228?' using SBOMs."
- "Quiz me: for each of the 20 stages, I'll name an attack or failure — you tell me if I placed the defending stage correctly."

## 🛠️ Hands-on 2.3 — First real build, forensics-style (2.5 h)

**Step 1 — publish the shared library to GitLab** (the controller loads it
from there, not from disk). Follow `documentation/installation.md` §12 —
in short: push `jenkins/shared-library/` into the
`platform/devsecops-shared-library` project (created by the GitLab scripts).

✅ **Checkpoint:** GitLab shows the repo with `vars/`, `src/`, `config/`.

**Step 2 — trigger the sample pipeline.** The GitLab seeding script created a
sample service repo (orders-api). Make a trivial commit (edit README) on a
branch → push → Jenkins' GitLab Branch Source picks it up (webhook or the
hourly scan; you can also click *Scan Multibranch Pipeline Now*).

**Step 3 — watch it live.** Jenkins → the branch job → Console Output
(timestamper is on). Do all of these WHILE it runs:
- find the language detection log line (Stage 1),
- find the image digest being recorded (Stage 9–12),
- find the `chore(gitops):` commit hash (Stage 16) — open it in GitLab,
- watch the stage view: which stages skip vs run and why (`when` flags).

**Step 4 — forensics on a finished build.** In the build page:
- **Artifacts** → `reports/` — open the JSON: unit tests, semgrep, trivy,
  syft SBOM, verify report, postdeploy report. This is your audit evidence.
- **Sonar** link → the quality gate detail page.
- **Nexus** → Browse → `docker-hosted`: your image; click it — see the digest.
  Search `raw-hosted` → the SBOM.
- **GitLab gitops-repository** → commit history of `applications/orders-api/
  overlays/dev/kustomization.yaml` — the digest pin, committed by
  `platform-devops-bot`.
- Notification: the Slack/email message with all §16 context fields.

✅ **Checkpoint:** you can point at five different systems that each hold a
piece of evidence for THIS build — and they all agree on one digest.

## 🏋️ Day-2 exercises — the Breaking Lab (do ALL; this is the day that teaches)

> Each exercise = push a deliberate flaw, predict where the pipeline stops,
> verify, then revert. Write your prediction BEFORE pushing — being wrong is
> the best learning moment of the day.

1. **Unit test failure.** Break an assertion → push. *Prediction target:*
   Stage 5. Observe: build result, which report shows it, what the
   notification says (`failedStage`).
2. **Committed secret.** Add `AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY`
   to a file → push. *Target:* Stage 3 (pre-build Gitleaks) — the build dies
   BEFORE compiling. Read the Gitleaks report: rule name, line, redaction.
   Delete the file AND note: the secret is now in git HISTORY — rotate any
   real key that ever suffered this. *Concept: why scanning pre-build matters.*
3. **Vulnerable code.** Add a classic Semgrep-catchable flaw, e.g. Python:
   `os.system("echo " + user_input)` or a Java SQL string-concat query →
   push. *Target:* Stage 7. Find the rule ID in the report; look it up in the
   pinned ruleset.
4. **Quality regression.** Delete most of a function's tests or duplicate 60
   lines → push. *Target:* Stage 6 quality gate. Compare Sonar's
   "new code" period verdict vs the old codebase.
5. **Trace the signature.** After a green build:
   `docker compose exec agent-security cosign verify --key <(cat secrets/cosign/cosign.pub) registry.<domain>/<team>/<svc>@<digest>`
   (or read Stage 12's log output). Find the signature in the registry.
   *Concept: this exact check happens AGAIN at the cluster gate tomorrow.*
6. **The exception register.** Read `security/exceptions/` + `SecurityGate.groovy`.
   Answer: who can add an exception, what fields are mandatory, and what
   happens when it expires? (Don't add one — just trace the code path.)
7. **Monorepo selective build (if time):** read `detectProject.groovy`'s diff
   logic; explain to the AI assistant how a change in `services/a/` avoids
   rebuilding `services/b/` — then have the AI quiz you on edge cases (shared
   library changes, Dockerfile base changes).

🤖 **Ask your AI assistant:**
- "I predicted stage X would catch my flaw but stage Y did. Here's the log: <paste>. Explain the ordering logic and why that's the better design."
- "Give me 5 more 'deliberate flaw' ideas to test a DevSecOps pipeline, ordered by subtlety, with the stage each should hit."

## 📝 Day-2 quiz

1. Why does the Jenkins controller have zero executors? Name two risks this eliminates.
2. What exactly is in the `reports/` artifacts of a build, and who consumes them?
3. A Critical CVE is found in a base-OS package INSIDE your image, but your app code is clean. Which stage catches it, and why doesn't Semgrep?
4. Explain in one sentence why the pipeline pins digests instead of tags.
5. The quality gate "waits" — why doesn't the pipeline just trust the scanner's exit code?
6. An exception for a High finding expired yesterday. What happens on the next build, and which file decides that?
7. Where does the cosign private key live, and which two places independently verify the signature?

<details><summary>Answers</summary>

1. Blast-radius + hygiene: a compromised/buggy build can't read controller
   credentials or plant persistence on the controller; agents are ephemeral
   containers reset between builds.
2. Machine + human evidence: test XML, semgrep/trivy/gitleaks JSON, SBOM
   (also in Nexus), verify + postdeploy JSON. Consumed by: developers (debug),
   auditors (compliance), the policy engine (gate decisions), notifications.
3. Stage 10 (Trivy image scan). Semgrep analyzes YOUR source patterns; the
   vulnerable code ships in an installed OS/library package — only an image
   scanner sees installed-package manifests.
4. A digest is the content hash of the image — immutable identity — so scanning,
   signing, deploying and verifying provably refer to the SAME bytes.
5. Sonar computes the gate asynchronously (CE task) after upload; the plugin's
   exit code only proves the upload worked. The step polls the CE task, then
   reads the actual gate verdict (branch-isolated to avoid cross-branch races).
6. The gate re-blocks: the exception register is consulted per build and
   entries past their `expires` date are treated as absent (fail-closed).
7. In Vault (`secret/platform/cosign`, seeded from `secrets/cosign.env`), exported
   to the signing agent at build time. Verified by (a) the cluster's Kyverno
   `verify-image-signature` policy at admission and (b) anyone with the public
   key via `cosign verify`; the verify step additionally proves the RUNNING
   pods match the signed digest.
</details>

---

# 📅 DAY 3 — GitOps, Kubernetes, and Progressive Delivery

## 🎯 Goals

By tonight you will be able to:
1. Explain pods, deployments, services, namespaces, and admission control — enough to operate, not just define.
2. Explain GitOps: why a git repo is the cluster's front door, and what ArgoCD does every few seconds.
3. Read the `gitops-repository` like a map: chart → base → overlays → environments.
4. Watch a canary rollout progress step by step, live.
5. Cause a bad deployment, watch verification catch it, and watch auto-rollback heal it — then explain every git commit involved.

## 📖 Theory block 3.1 — Kubernetes crash course for pipeline people (60 min)

The minimum viable mental model (you'll *use* all of this in the afternoon):

- **Pod** — one or more containers sharing network+storage. The atom. Pods are
  cattle: killed, replaced, rescheduled constantly. Never pet a pod.
- **Deployment** — declares "N replicas of this pod template, updated this way."
  The controller makes reality match the declaration, forever. This
  *declarative + self-healing loop* is the core Kubernetes idea.
- **Service** — a stable DNS name + load balancer in front of changing pods
  (`orders-api.orders-api-dev.svc.cluster.local`).
- **Namespace** — an isolation boundary. This platform runs one per
  app-per-environment: `orders-api-dev`, `orders-api-prod`, … ArgoCD
  *projects* restrict which app may touch which namespaces.
- **kubeconfig** — a client identity+address file. Jenkins holds a READ-ONLY
  one (can `get`/`list` workloads, pods, events, logs; can port-forward; can
  NOT create/delete/exec — verified with `kubectl auth can-i` in installation §14.3).
- **Admission control** — BEFORE an object is stored, webhooks inspect it.
  **Kyverno** is our webhook: policies in Enforce mode REFUSE non-compliant
  pods. Two policies guard every namespace: images must be
  `registry.<domain>/…@sha256:…` (digest-pinned) AND carry a valid cosign
  signature. The cluster doesn't trust the pipeline — it verifies independently.
- **kubectl survival kit** (you'll live in these today):

```bash
kubectl get pods -n orders-api-dev -o wide          # what runs, where, ready?
kubectl describe pod <pod> -n <ns>                  # events: WHY it's unhappy
kubectl logs <pod> -n <ns> [--previous]             # app output (crash before?)
kubectl get events -n <ns> --sort-by=.lastTimestamp # the namespace's diary
kubectl get deploy,svc,rollout -n <ns>              # the workload inventory
kubectl auth can-i <verb> <resource> -n <ns>        # what may I do here?
```

🤖 **Ask your AI assistant:**
- "Teach me Kubernetes deployments vs statefulsets vs daemonsets with one real example each from a CI/CD platform."
- "I'll describe a broken pod state (CrashLoopBackOff / ImagePullBackOff / Pending / OOMKilled) — quiz me on first diagnostic command for each and what the fix usually is."

## 📖 Theory block 3.2 — GitOps: the repo IS the cluster (45 min)

**The rule:** nobody `kubectl apply`s, nobody SSHes, nobody clicks in a
dashboard to change a running system. You change **git**; ArgoCD (running
in-cluster, polling git every ~3 min or on-demand) makes reality match.

Why this beats "pipelines that kubectl apply":
- **Audit**: `git log` is the deployment history; every change has an author,
  a message, a diff.
- **Rollback**: `git revert` (the platform automates exactly this — Stage 19).
- **Drift healing**: manual `kubectl edit` gets detected and reverted.
- **Least privilege**: Jenkins never holds cluster-write credentials — only
  git-push (to one repo) + ArgoCD-sync (scoped API account). Compromise the
  pipeline → you can propose commits (reviewed, revertable), not mutate pods.

**The repository layout** (`gitops-repository/`, seeded in GitLab):

```
helm-charts/microservice-standard/   ONE chart for ALL services
  values.yaml                        defaults: hardened securityContext, probes,
                                     NetworkPolicy, PDB, HPA, rollout strategy…
  templates/                         deployment OR rollout (rollout.enabled),
                                     service (+preview for blue-green), hpa
                                     (follows the workload kind), pdb,
                                     networkpolicy, externalsecret, _helpers
applications/orders-api/
  values.yaml                        this service's values (image name, port,
                                     rollout: canary ENABLED with steps)
  base/manifests.yaml                the chart RENDERED AND COMMITTED ("render-
                                     and-commit": the cluster applies plain YAML;
                                     git diffs show EXACTLY what changed)
  overlays/{dev,qa,uat,prod}/        Kustomize patches per environment:
                                     replicas (1/1/2/3), resources, canary step
                                     tuning, the DIGEST PIN (images: field),
                                     prod: JSON6902 patches + PDB minAvailable=2
clusters/…                           ArgoCD app-of-apps: AppProjects (one per
                                     env, namespace-restricted) + ApplicationSets
                                     (one Application per app-per-env)
```

**Three subtleties worth understanding deeply** (all documented with live-proven
fixes in `documentation/gitops.md` §9.3):
1. A **Rollout** (Argo Rollouts CRD) replaces the Deployment when
   `rollout.enabled: true` — canary steps like `setWeight: 50 → pause 10s → 100`.
   ArgoCD natively understands Rollout health; the pipeline's verify step polls
   `.status.phase` (Healthy/Degraded/Paused).
2. Kustomize's built-in `replicas:` transformer doesn't know CRDs — each
   overlay carries a tiny `replicas-config.yaml` teaching it `spec/replicas`
   for kind `Rollout`.
3. Patching a CRD's pod template with strategic-merge semantics REPLACES whole
   lists (containers!) — so pod-spec edits use JSON6902 ops. (You don't need to
   memorize this; you need to know the repo documents these traps.)

**Secrets in GitOps.** Values files carry secret NAMES, never values. The
chart renders an **ExternalSecret** object; the **External Secrets Operator**
in-cluster authenticates to Vault (Kubernetes SA auth via TokenReview — no
static tokens) and materializes a native Secret. `verifyDeployment` checks
ExternalSecrets are `Ready=True` — a missing Vault secret fails the deploy, loudly.

🤖 **Ask your AI assistant:**
- "Compare push-based vs pull-based GitOps (Jenkins-kubectl vs ArgoCD). Why does pull-based reduce the credential blast radius?"
- "Explain the app-of-apps pattern and ApplicationSets — why not one Application per service created by hand?"
- "Walk me through what happens, object by object, from `git push` on a gitops overlay commit to a pod serving traffic."

## 📖 Theory block 3.3 — Progressive delivery + verification + rollback (30 min)

- **Canary (Argo Rollouts):** new version starts beside the old; traffic shifts
  in steps (prod: 10% → 30% → 60% → 100% with 2-minute observation pauses).
  A `Degraded` rollout stops; verify fails the build; auto-rollback re-pins the
  previous digest. Bounded pauses matter: an *indefinite* manual pause would
  hang verification forever (config `verify.acceptPaused` exists for teams that
  deliberately want a human gate).
- **Blue-green:** a full parallel "preview" stack; promote = switch the Service
  selector. The chart supports both; orders-api ships canary.
- **Auto-rollback mechanics (memorize — it's beautiful):** on verify/smoke
  failure the step runs `git log -- <that overlay's kustomization.yaml>`,
  walks history for the previous REAL digest (never the zeros placeholder),
  pins it, commits `revert(gitops): rollback svc@env → sha256:… (reason)`,
  ArgoCD heals the cluster in seconds. The BUILD STILL FAILS — rollback
  restores the service; it never excuses the change.

## 🛠️ Hands-on 3.4 — Cluster up, first GitOps deploy (2.5 h)

**Step 1 — install the lab cluster (K3s).**

```bash
./kubernetes/k3s/install-k3s.sh
# What it does (READ the script while it runs ~3 min):
#  - installs pinned K3s with its built-in Traefik DISABLED (ours is the edge;
#    two ingress controllers fight over ports 80/443) + servicelb off
#  - writes node /etc/hosts for vault.<domain> + trusts the platform CA
#  - configures registries.yaml: docker.io/quay.io/ghcr.io MIRROR THROUGH NEXUS
#    (nodes never pull from the internet directly — supply-chain control)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml    # add to your shell profile
kubectl get nodes                              # ✅ one Ready node
```

(Production with an existing cluster: `./kubernetes/scripts/10-register-cluster.sh`
instead — same downstream flow.)

**Step 2 — bootstrap the cluster tooling.**

```bash
./kubernetes/scripts/00-bootstrap-cluster.sh
# Runs in order (each idempotent, each a readable script):
#  ArgoCD (NodePort 30443, admin password → secrets/argocd.env, jenkins-cd
#          least-priv account, app-of-apps root)
#  Kyverno + our two Enforce policies (verify-image-signature with the cosign
#          PUBLIC key inline, require-digest-pinning)
#  Argo Rollouts (canary/blue-green controller)
#  External Secrets Operator + Vault Kubernetes auth per cluster
#          (vault/scripts/30-k8s-auth.sh: TokenReview identity, eso-reader role)
./kubernetes/scripts/20-verify-kubeconfig.sh   # the READ-ONLY verifier identity
kubectl get pods -A | grep -Ev "Running|Completed"   # ✅ empty (or give it 2 min)
```

**Step 3 — seed the gitops repository + watch app-of-apps cascade.**

```bash
./gitlab/scripts/50-gitops-repository.sh   # pushes gitops-repository/ into GitLab
# ArgoCD root app → AppProjects (dev/qa/uat/prod) → ApplicationSets →
# one Application per app-per-env. Log into ArgoCD:
#   https://argocd.<domain> (or NodePort 30443) — admin / secrets/argocd.env
```

✅ **Checkpoint:** ArgoCD UI shows `orders-api-dev` **Synced + Healthy** within
minutes. Click into it: see the resource tree (Rollout, Service, PDB,
NetworkPolicy, ExternalSecret…). This deployed with ZERO `kubectl apply` from
you.

**Step 4 — ground-truth with kubectl (30 min, do every command).**

```bash
kubectl get rollout orders-api -n orders-api-dev -o yaml | head -60
#    find: spec.replicas, the canary steps, the image …@sha256:… pin
kubectl get pods -n orders-api-dev -o jsonpath='{.items[*].spec.containers[*].image}'
#    ✅ ends with the SAME digest as the gitops overlay — the identity contract
kubectl get externalsecret -n orders-api-dev     # Ready=True → Vault chain works
kubectl get policyreport -A                      # Kyverno verdicts (empty = all compliant)
kubectl auth can-i delete pods -n orders-api-dev # your admin: yes. The verifier SA:
kubectl auth can-i delete pods -n orders-api-dev \
  --as=system:serviceaccount:platform-tools:deploy-verifier   # ✅ no
kubectl auth can-i create pods/portforward -n orders-api-dev \
  --as=system:serviceaccount:platform-tools:deploy-verifier   # ✅ yes (smoke tests)
```

**Step 5 — end-to-end: push code, watch it reach the cluster.**
Commit a change to the sample service repo (Day-2 flow). In one terminal:
`kubectl get rollout -n orders-api-dev -w`. In another: the Jenkins console.
Correlate: Stage 16 commit → ArgoCD sync → canary steps tick by → Stage 18
verify passes → notification lands.

## 🏋️ Day-3 exercises (the delivery lab — do ALL)

1. **Change replicas the GitOps way.** Edit `overlays/dev` replicas 1→2 in the
   gitops repo, commit, watch ArgoCD sync it (or trigger sync from Jenkins'
   promotion job). Verify with kubectl. Now `kubectl scale deploy --replicas=3`
   by hand and WATCH ARGOCD REVERT YOU (drift healing; may take up to the sync
   interval). *Concept: git is the only door.*
2. **Break a deployment → auto-rollback (THE exercise of the week).** In the
   gitops repo's dev overlay, patch the Rollout's container env with something
   crash-loop-inducing (e.g. an env var the app requires but you set invalid,
   or point the command at `/bin/false` via a JSON6902 patch if the sample app
   allows). Commit. Watch: ArgoCD syncs → pods CrashLoopBackOff →
   `verifyDeployment` pathology scan fails → `revert(gitops):` commit appears →
   cluster heals → build FAILED + `deployment_failed` notification. List every
   commit in the overlay's history afterwards — that's your audit trail.
3. **Kyverno rejection.** In a scratch branch of the gitops repo, change the
   dev image to a mutable tag (`registry.<domain>/team/svc:latest`) and sync.
   `kubectl get policyreport -n orders-api-dev -o yaml` → find the
   require-digest-pinning verdict. The ReplicaSet's pods are simply never
   created. Revert. *Concept: the cluster verifies independently of CI.*
4. **Promote a digest.** Use Jenkins job `platform/gitops-promotion`
   (or the `promoteDigest` step) to move orders-api dev→qa. Diff the qa
   overlay commit. Note: SAME digest — nothing was rebuilt. *Concept: artifact
   promotion, not re-compilation.*
5. **Read a canary like an SRE.** Trigger any dev deploy and in parallel run
   `kubectl argo rollouts get rollout orders-api -n orders-api-dev --watch`
   (the argo CLI is on agent-general; or watch `kubectl get rollout -o yaml`'s
   status). Map each observed step to `overlays/dev`'s step list and to the
   chart's `rollout:` values. Then answer: why are prod's pauses 2 minutes and
   dev's 10 seconds?
6. **Secrets chain.** `kubectl get secret -n orders-api-dev` — find the
   ESO-materialized secret; then in Vault: `docker compose exec vault vault
   kv get secret/apps/orders-api/db-creds`. Change the Vault value, force ESO
   resync (annotate the ExternalSecret), watch the K8s Secret update WITHOUT a
   git commit. *Concept: secrets flow Vault→ESO, never through git.*

🤖 **Ask your AI assistant:**
- "Here is my `kubectl describe pod` output for the crashed exercise-2 pod: <paste>. Explain the events chronologically and which platform component reacted at each point."
- "Explain ArgoCD sync waves and health assessment for a Rollout CRD — how does 'Healthy' differ from 'Synced'?"
- "Quiz me: I'll paste gitops overlay diffs; you ask me to predict the ArgoCD + pipeline behavior before revealing it."

## 📝 Day-3 quiz

1. In one sentence each: why does Jenkins hold a git-push token but NOT cluster-admin credentials?
2. What is the difference between ArgoCD "Synced" and "Healthy"?
3. The base manifests are COMMITTED rendered YAML, not a Helm release in-cluster. Give two advantages.
4. Why must the verify step check that running pods' images end with the build's digest — didn't Kyverno already guarantee a signed image?
5. During auto-rollback, why does the step search the overlay file's OWN git history (`git log -- <path>`) instead of the repo's global log?
6. An ExternalSecret is not Ready. Name three possible root causes across the chain.
7. Why are canary pauses "bounded" (30s/2m) instead of indefinite manual approvals by default?

<details><summary>Answers</summary>

1. Least privilege / blast radius: git commits are reviewed, revertable and
   rate-limited by policy; cluster-write credentials would let a compromised
   pipeline mutate anything instantly and untraceably.
2. Synced = cluster manifests match git. Healthy = the resulting workloads
   actually work (pods ready, Rollout phase Healthy). Synced-but-Degraded is
   exactly the state verify/auto-rollback exists for.
3. (a) Auditable diffs — a commit shows the exact YAML delta, no Helm client or
   values archaeology needed; (b) the cluster needs no Helm/plugins/registry
   access at apply time — plain manifests, simpler and fewer moving parts.
4. Kyverno guarantees A signed, pinned image was admitted; it can't guarantee
   the rollout FINISHED — old pods may still serve, the rollout may be paused
   or degraded, or replicas may be stuck. Verify checks the LIVE end-state
   equals the intended digest everywhere.
5. Global history interleaves commits from other services; a file-scoped log
   yields exactly this environment's digest lineage — the previous real pin is
   commits[1]'s digest, immune to unrelated churn (and to the zeros placeholder).
6. Vault sealed/unreachable; the ESO ClusterSecretStore auth broken (SA/
   TokenReview wiring); the secret path missing or the eso-reader policy/role
   mismatch; (bonus) network policy blocking egress.
7. Verification must converge within a timeout to give the pipeline a verdict;
   indefinite pauses stall every build. Teams wanting a human gate opt in
   deliberately (`acceptPaused` + explicit pause), knowing the trade-off.
</details>

---

# 📅 DAY 4 — Observability, Disaster Recovery, and the Capstone

## 🎯 Goals

By tonight you will be able to:
1. Explain the three pillars (metrics, logs, alerts) and how THIS platform implements each.
2. Read and write basic PromQL/LogQL; find anything on the 5 dashboards.
3. Explain SLOs, error budgets, and burn-rate paging like an SRE.
4. Trace both notification paths (infra alerts + pipeline events) end to end.
5. Take a backup, restore from it, and explain the Vault unseal-key rule.
6. **Capstone:** onboard YOUR OWN microservice end-to-end, unassisted.

## 📖 Theory block 4.1 — Metrics: Prometheus + the SLO idea (45 min)

**Pull model.** Prometheus *scrapes* every component's `/metrics` endpoint
every 30s (jobs: jenkins, gitlab-exporter, nexus, vault, traefik, loki, alloy,
node-exporter, cadvisor…). Each sample = metric name + labels + value +
timestamp. That's it — everything else is query language:

```promql
up{job="jenkins"}                                     # 1 = alive, 0 = down
jenkins_queue_size_value                              # builds waiting
rate(traefik_service_requests_total{code=~"5.."}[5m]) # 5xx per second
100 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100   # CPU %
```

**Alerts = rules evaluated continuously** (`monitoring/prometheus/rules/`):
`expr` + `for` (must stay true this long) + labels (severity routes them) +
annotations (the human text). Three families: platform baseline (host/containers),
CI/CD (queue backlog, agents offline, **VaultSealed**, …), and SLO burn rates.

**SLOs — reliability as a budget.** The platform promises *itself* 99.5%
availability (fraction of the 5 critical scrape targets that are UP) and each
routed service 99.9% success (1 − Traefik 5xx ratio). 99.5%/30 days = a 0.5%
**error budget** ≈ 3.6 hours of allowed downtime. Alerts don't fire on single
blips — they fire on **burn rate**: consuming the budget 14.4× fast (two-day
death spiral → page a human) or 6× slow (five-day → ticket). Multi-window
(5m AND 30m) prevents one bad minute from paging anyone. This is the industry
standard (Google SRE workbook) — you now have it running locally.

**Watchdog.** An alert that ALWAYS fires, routed to a no-op receiver. If an
external checker stops seeing it, the entire alerting path is dead. Absence of
bad news is not news; presence of the heartbeat is.

🤖 **Ask your AI assistant:**
- "Teach me PromQL from zero: range vectors, rate vs increase vs avg_over_time, label matching. Then give me 5 exercises against a CI/CD platform's metrics."
- "Explain multi-window multi-burn-rate alerting with a concrete timeline: what fires when, for a 99.5% SLO, during a 20-minute outage?"

## 📖 Theory block 4.2 — Logs: Alloy → Loki, and log-derived alerts (25 min)

**Alloy** (the collector) discovers EVERY compose container through the
*socket proxy* (never the raw Docker socket — least privilege) and ships logs
to **Loki** (storage optimized for logs: index the LABELS, compress the text).
Before ingestion it DROPS healthcheck noise (`/-/healthy`, `wget -qO-`…) —
compose healthchecks fire every 30s per container and would drown real signal.

Query language (LogQL) looks like a stream selector + filters:

```logql
{service="jenkins"} |= "ERROR"                       # lines containing ERROR
{project=~".+"} |~ "(?i)\\b(error|fatal|panic)\\b"   # regex across everything
sum by (service) (rate({project=~".+"} |~ `(?i)error` [5m]))   # metric FROM logs
```

That last one is the magic: Loki's **embedded ruler** evaluates log-derived
metrics and alerts through the SAME Alertmanager as Prometheus (rules in
`monitoring/loki/rules/fake/`: per-service error spikes, Vault seal events *in
log text*, Jenkins OutOfMemoryError stack traces). Failure modes that exist
only in text still page you.

## 📖 Theory block 4.3 — Notifications: two paths, one script (20 min)

```
PATH A (infrastructure):  Prometheus/Loki rules → Alertmanager → routes:
        severity=critical → oncall-critical (Slack + Teams + email, 1h repeat)
        everything else   → platform-default (Slack + email, 12h repeat)
        severity=none     → watchdog sink (heartbeat terminus)
PATH B (pipelines):       notifyResult step → Slack/Teams webhook creds + SMTP
        events: build_completed/failed, deployment_started/completed/FAILED,
        ROLLBACK_EXECUTED, quality_gate_failed, critical_vulnerability…
```

Same endpoints, independent paths — a dead Jenkins still pages on-call; a dead
Alertmanager never loses build notifications. All secrets are FILES
(`secrets/alertmanager/*`) with parse-safe placeholders from bootstrap (both
daemons validate file contents at startup — a missing file would crash them).
One script (`monitoring/scripts/20-configure-notifications.sh`) flips real
values on and enables only the channels you actually configured.

## 🛠️ Hands-on 4.4 — Wire the nervous system (1.5 h)

```bash
# 1) Nexus scrape target (capability + zero-privilege 'metrics' user)
./monitoring/scripts/10-enable-nexus-metrics.sh

# 2) Notifications: put real values in .env first (SMTP_HOST/USER, mailboxes,
#    SLACK_WEBHOOK_URL, TEAMS_WEBHOOK_URL) — or leave empty to watch the
#    fail-safe skips. Then:
./monitoring/scripts/20-configure-notifications.sh
docker compose up -d jenkins

# 3) Vault hardening chain (vault must be unsealed; VAULT_ROOT_TOKEN in
#    secrets/vault-root.env):
./vault/scripts/40-platform-secrets.sh     # seed secret/platform/{notifications,cosign}
./vault/scripts/50-jenkins-approle.sh      # 1h-token identity for Jenkins
./vault/scripts/60-audit-enable.sh         # audit → Alloy tail → Loki

# 4) Backups:
./scripts/backup-now.sh                    # native dumps + restic + integrity check

# 5) Prove the whole alerting path end-to-end:
docker compose exec prometheus wget -qO- http://localhost:9090/api/v1/targets \
  | jq -r '.data.activeTargets[] | "\(.labels.job)=\(.health)"' | sort -u   # all healthy
docker compose exec alertmanager wget -qO- http://localhost:9093/api/v2/alerts \
  | jq 'map(.labels.alertname) | unique'                                    # Watchdog present
docker compose exec alertmanager wget -qO- --header='Content-Type: application/json' \
  --post-data='[{"labels":{"alertname":"LearningTest","severity":"warning"},"annotations":{"summary":"Hello from Day 4"}}]' \
  http://localhost:9093/api/v2/alerts                                       # → Slack/email arrives!
```

✅ **Checkpoint:** the LearningTest alert reached your configured channel;
Grafana shows 5 dashboards; `{service="vault-audit"}` appears in Loki labels
after any Vault operation.

## 🏋️ Day-4 exercises

1. **Dashboard tour with questions.** In Grafana, answer without help:
   Which service burned the most CPU in the last hour? What is the current
   30-day platform availability? Which container restarted most this week?
   How many log lines/s is GitLab producing? What's the p99 Jenkins build
   duration? (Panels: infra, overview, logs, cicd — one each.)
2. **Fire a real alert.** `docker compose stop nexus` for 6 minutes. Watch
   TargetDown → group_wait → Slack. Restart. Watch the RESOLVED notification.
   Find the inhibit rule that would silence warnings if a critical fired for
   the same alertname (`alertmanager.yml`).
3. **Write YOUR OWN alert rule.** Add to `monitoring/prometheus/rules/cicd.yml`:
   alert when Grafana's login page has been down 5m (`up{job=~".*grafana.*"}` —
   first add a grafana scrape job; discover its metrics port yourself). Reload
   Prometheus (`docker compose exec prometheus kill -HUP 1`), test it by
   stopping Grafana. *Concept: alerting is code — review it like code.*
4. **SLO math by hand.** Compute: with a 99.5%/30d SLO, how many minutes of
   downtime remain if 2.1 hours were already consumed? At 14.4× burn, how long
   until exhaustion? Verify your intuition against the Overview dashboard's
   burn-rate gauge.
5. **Restore drill (mini).** `./scripts/restore.sh list` → pick the newest
   snapshot → restore ONLY Grafana's data to a temp dir and diff a dashboard
   file. Then read `backup-recovery.md` §5 (bare-metal DR) and §4 (why the
   Vault unseal keys are NEVER in the backup). Quiz yourself: your host died
   AND secrets/ died. What can you restore, and what is lost forever if the
   key envelopes are also gone?
6. **Vault least-privilege proof.** Using the AppRole creds from
   `secrets/vault-jenkins.env`, log in and try reading
   `secret/apps/orders-api/db-creds` — expect PERMISSION DENIED (that path
   belongs to the cluster's ESO identity only). Then read
   `secret/platform/notifications` — allowed. *Concept: policy boundaries you
   can feel.*

## 🎓 THE CAPSTONE — onboard your own microservice (2–3 h)

The graduation test. Take a small service of YOURS (or write a 30-line
FastAPI/Express/Spring app with one `/health` endpoint and 2 unit tests).

1. Push it to GitLab under your team group (mirror the sample repo's layout).
2. Add the 10-line Jenkinsfile (`@Library(...) _ ; microservicePipeline()`).
3. Add `tests/postman/smoke.postman_collection.json` (one GET {{BASE_URL}}/health)
   and/or `tests/k6/load.js` with one threshold — discover the conventions in
   `runPostDeploy.groovy`.
4. Create `gitops-repository/applications/<your-svc>/` by copying orders-api:
   values.yaml (image name, port), 4 overlays (start dev-only; copy the
   replicas-config.yaml pattern). Render base with
   `gitops-repository/scripts/render-app.sh`.
5. Seed its Vault secret (`vault kv put secret/apps/<your-svc>/db-creds …`)
   and make sure its ExternalSecret template matches.
6. Push → watch the FULL journey: build → scans → signed digest → gitops
   commit → ArgoCD → canary → verify → YOUR smoke test passing → notification.
7. Then break it on purpose (exercise Day-3 #2) and watch YOUR service
   auto-rollback.

✅ **Graduation checkpoint:** you did all 7 without re-reading Part 3/4 theory,
and you can explain each hop's *why* out loud. If you got stuck, the next
section tells you exactly which doc re-teaches it.

## 📝 Day-4 quiz

1. Why does the platform alert on BURN RATE instead of "availability < 99.5% right now"?
2. What does the Watchdog alert protect against that no other alert can?
3. Why are healthcheck log lines dropped at Alloy instead of filtered at query time in Grafana?
4. A pipeline fails at verify and auto-rollback runs. Exactly which notification EVENTS fire, in order, and via which path (A or B)?
5. Why does Alertmanager use `*_file` secret references with parse-safe placeholders instead of inline values or "no config until configured"?
6. Your restore of Vault from a raft snapshot succeeded, but ESO in the cluster can't authenticate anymore. Why, and what's the fix?
7. One sentence: why is `secrets/` deliberately NOT inside the restic backup scope?

<details><summary>Answers</summary>

1. Instant availability is noisy (one blip ≠ incident) and slow (30d window
   barely moves). Burn rate measures VELOCITY of budget consumption: 14.4× means
   "at this pace the month's reliability is gone in 2 days" — urgent AND sustained
   (multi-window), so pages mean action, not weather.
2. Failure of the alerting system itself. Every other alert depends on
   Prometheus→Alertmanager→channel working; Watchdog's ABSENCE (checked externally)
   is the only signal that can report "the smoke detector is unplugged."
3. Cost + signal: they'd consume ingestion budget and storage (every 30s per
   container forever) and inflate error-rate log alerts (the ruler counts lines
   matching error patterns — noise raises false positives). Dropping at the edge
   fixes volume, cost AND alert quality; query-time filters fix nothing upstream.
4. Path B: `deployment_failed` (fired by verify the moment the verdict is in) →
   `rollback_executed` (fired by rollbackDeployment after the revert commit/sync)
   → `build_failed` (post{} block). Path A may ALSO fire later (TargetDown/
   ContainerRestarting/SLO burn) from the cluster-side symptoms — independent by design.
5. Both daemons validate config (and file contents) at startup: inline secrets
   would live in git; missing files crash the process. URL/host-shaped placeholders
   let config load and fail only per-delivery — the platform stays observable
   before it is notifyable.
6. The snapshot restored the cluster's Kubernetes-auth identities as of snapshot
   time; tokens/roles created after it are gone (or the ESO SA token rotated).
   Fix: re-run `vault/scripts/30-k8s-auth.sh` (idempotent) — and rerun
   `50-jenkins-approle.sh` for the same reason on the Jenkins side.
7. `secrets/` holds LIVE credentials; a backup repository (possibly off-host,
   possibly at a provider) must not become a second copy of the keys to the
   kingdom. Secret material follows your secret-custody process; the Vault
   unseal-key envelopes live off-host by definition (§4 of backup-recovery.md).
</details>

---

# 📚 APPENDICES

## A. Troubleshooting cheat-sheet (first 5 commands for any problem)

```bash
docker compose ps --format "table {{.Name}}\t{{.Status}}"   # who's unhealthy?
docker compose logs --tail=100 <service>                   # why?
./scripts/health-check.sh                                  # platform's own verdict
kubectl get pods -A | grep -v Running                      # cluster side
kubectl get events -A --sort-by=.lastTimestamp | tail -20  # cluster diary
```
Then: Grafana → Platform Overview (what's down/burning) → Platform Logs
(`{service="<suspect>"} |= "error"`). Still stuck → paste logs into the 🤖 box.

| Symptom | First suspect | Doc |
|---|---|---|
| Jenkins job never triggers | GitLab webhook / branch-source scan | installation §12, gitlab/scripts/add-webhook.sh |
| Build fails "SET_IN_PHASE_N" | that phase's setup script not run | installation § for that phase |
| Image push 401 | nexus-deploy creds / registry auth | security.md §1 |
| ArgoCD OutOfSync forever | render-and-commit drift; check base vs chart | gitops.md §3–5 |
| Pods refused by Kyverno | unsigned image or mutable tag | gitops.md §7, Day-3 ex.3 |
| Verify times out on Paused | canary pause > verify.timeoutSec | gitops.md §9.4 |
| No Slack notifications | configure-notifications not run / placeholder | observability.md §6–8 |
| Vault sealed after restart | normal! unseal with 3 shares | backup-recovery.md §4 |
| Alerts silent | Watchdog missing? path dead | observability.md §2, §8 |
| Loki empty | Alloy/socket-proxy, or drop-stage too broad | observability.md §5, §8 |

## B. Component ↔ file map ("where does X live?")

| Want to change… | Edit… | Then… |
|---|---|---|
| a pipeline stage / gate | `jenkins/shared-library/vars/*.groovy` + `config/platform-config.yaml` | push library (installation §12) |
| which tools run in builds | `jenkins/agents/<x>/Dockerfile` | `./scripts/build-images.sh --agent <x>` + recreate |
| Jenkins system config/creds | `jenkins/casc/*.yaml` + `secrets/*.env` | `docker compose up -d jenkins` |
| deployment shape of ALL services | `gitops-repository/helm-charts/microservice-standard/` | render-app + commit (the pipeline does it) |
| one env's replicas/resources/steps | `applications/<svc>/overlays/<env>/kustomization.yaml` | commit → ArgoCD (never kubectl) |
| cluster admission rules | `kubernetes/kyverno/policies/` | `kubectl apply` via install scripts |
| metric alerts / SLO objectives | `monitoring/prometheus/rules/*.yml` | `kill -HUP 1` prometheus |
| log alerts | `monitoring/loki/rules/fake/*.yml` | restart loki |
| dashboards | `monitoring/grafana/dashboards/*.json` | auto-reload ≤60s |
| notification endpoints | `.env` → `monitoring/scripts/20-configure-notifications.sh` | script does reloads |
| backup scope/cadence | compose `backup` service + `.env` + cron | backup-recovery.md §3,7 |
| TLS posture | `reverse-proxy/configuration/dynamic.yml.tmpl` | bootstrap + restart traefik |
| who may log in / do what | `jenkins/casc/10-security.yaml` (or optional-casc realm kits) | security.md §2, §8 |

## C. Expanded glossary

*(Day-0 terms you must know: git, branch, merge request, Docker image/container,
YAML, HTTP status codes. Everything platform-specific is below.)*

| Term | Plain meaning |
|---|---|
| Pipeline / Stage / Step | The automated journey / one phase of it / one unit of work |
| Shared library | Pipeline logic published once, consumed by every repo in ~10 lines |
| Agent (CI) | Disposable worker container that executes stages |
| Multibranch job | Jenkins auto-creating one job per branch/MR from the repo |
| Webhook | "POST this URL when X happens" — GitLab→Jenkins trigger (secret-verified) |
| Artifact | Kept output: JAR/npm package/image/report/SBOM |
| Registry | Docker image warehouse (our Nexus `docker-hosted`) |
| Digest (`sha256:…`) | Content fingerprint of an image — immutable identity |
| SBOM | Ingredient list of an artifact (Syft → JSON/SPDX in Nexus) |
| SAST / SCA / secrets scan | Code-pattern security / dependency-CVE / leaked-credentials scanning |
| Quality gate | Pass/fail bar on Sonar metrics for NEW code |
| Exception register | Formal, EXPIRING allowlist for accepted findings (owner + ticket + date) |
| Cosign sign/verify | Cryptographic proof of image origin; cluster re-verifies at admission |
| Helm chart | Parameterized K8s manifest templates (ours: microservice-standard) |
| Kustomize overlay | Env-specific patch layer over shared base manifests |
| Render-and-commit | CI renders the chart to plain YAML and COMMITS it; cluster applies plain files |
| GitOps / ArgoCD | Git as the only door; a controller continuously matching cluster to repo |
| App-of-apps / ApplicationSet | ArgoCD patterns: a root app managing apps; template-generated apps per env |
| Drift | Cluster ≠ git; ArgoCD detects and heals it |
| Admission webhook / Kyverno | Pre-storage validation; our Enforce policies refuse non-compliant pods |
| Pod / Deployment / Rollout / Service / Namespace | K8s atom / replica manager / progressive-delivery manager / stable DNS+LB / isolation boundary |
| Canary / blue-green | Gradual traffic shift / parallel preview stack then switch |
| HPA / PDB | Autoscale replicas on load / guarantee minimum availability during disruptions |
| ESO / ExternalSecret | Operator syncing Vault values into native K8s Secrets |
| kubeconfig | Client identity+address for a cluster; Jenkins' is READ-ONLY (+port-forward) |
| Seal / unseal / unseal keys | Vault boots locked; 3-of-5 OFF-HOST key shares unlock it |
| AppRole (Vault) | Machine login: role-id + secret-id → short-lived policy-scoped tokens |
| KV v2 | Vault's versioned key-value secret engine (`secret/…`) |
| SLI / SLO / error budget | The measurement / the target / allowed failure = 1 − target |
| Burn rate | Budget-consumption speed; 14.4× ≈ budget gone in 2 days |
| Multi-window alert | Fast+slow windows must BOTH breach → no single-blip pages |
| Watchdog | Always-firing heartbeat; absence = alerting path dead |
| PromQL / LogQL | Prometheus / Loki query languages |
| Inhibition / grouping / repeat_interval | Alertmanager noise control: silence lower severities, batch, re-notify cadence |
| restic / native dump | Encrypted dedup file backups / app-consistent "save games" (raft, pg_dump…) |
| RPO / RTO | Max data loss tolerable / max time to recover |
| Idempotent | Rerun-safe: same end state, no double-effects |
| Fail-closed / fail-safe | Missing thing = loud error / non-critical failure never breaks the build (notifications) |
| Profile (compose) | Service group started selectively (core/monitoring/agents/backup/build) |
| Internal CA | Self-hosted certificate issuer; clients import ca.crt once |

## D. Your 4-day schedule at a glance

| Day | Morning theory | Afternoon hands-on | Evening proof |
|---|---|---|---|
| 1 | Compose, secrets, TLS, repo tour | bootstrap → images → stack up → all UIs → setup scripts | 6 UIs logged in; health-check green; ex. 1–4 done |
| 2 | Library pattern, 20 stages, trust chain | publish library → first build → forensics on reports | Breaking-lab exercises 1–5 done; predictions written |
| 3 | K8s crash course, GitOps, canary/verify/rollback | K3s → bootstrap cluster → gitops seed → kubectl ground truth | Exercises 1–6 incl. auto-rollback witnessed live |
| 4 | Metrics/SLO, logs, notifications, DR | monitoring+vault+backup scripts → test alert → drills | Capstone: YOUR service onboarded, broken, self-healed |

## E. After graduation

- Re-read `documentation/architecture.md` decisions D-01…D-38 — after the
  hands-on days, every decision will now *feel* obvious. That's the goal.
- Go deeper on ONE component per week (Vault and ArgoCD reward it most):
  read its scripts line by line, then re-run them watching the logs.
- Try a variation the platform supports but the guide didn't force: blue-green
  instead of canary (`rollout.strategy: blueGreen`), a second cluster
  (`10-register-cluster.sh` + multi-cluster docs), `TLS_MODE=letsencrypt`,
  LDAP/OIDC realm cutover, off-host restic repo.
- Teach it: explain the digest trust chain to a colleague in 5 minutes.
  If you can, you own it.

> 💡 **Closing thought:** you didn't "learn 20 tools" this week. You learned
> ONE idea, layered: *every change is a verified, signed, reviewable, revertable
> git event — and the machines enforce that promise at every hop.* The tools
> are interchangeable; the idea is the career skill.
