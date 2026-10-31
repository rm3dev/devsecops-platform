# Performance & capacity (Phase 11)

The platform ships with per-service CPU/memory limits (`.env` sizing knobs →
compose `deploy.resources`). This document maps the knobs, states honest
capacity expectations per tier, analyzes each pipeline-stage bottleneck, and
gives the load-verification procedure. Watch it live: Grafana →
`devsecops-overview` / `devsecops-infra` / `devsecops-cicd`.

## 1. Sizing knobs (.env → compose limits)

| Service | CPU | MEM | Notes |
|---|---|---|---|
| gitlab | GITLAB_CPU_LIMIT | GITLAB_MEM_LIMIT | omnibus floor ≈ 4 GB (reservations enforce); P11 exporters add ≈ 300 MB |
| jenkins | JENKINS_CPU_LIMIT | JENKINS_JAVA_XMX + ~1 GB | controller does NO builds (0 executors, D-05) — heap mostly serves UI/queue |
| sonarqube | SONAR_* | ≥ 3 GB | CE workers + ES inside one JVM |
| nexus | NEXUS_* | ≥ 3 GB | OrientDB + blob cache |
| vault | fixed small | 512M-ish | raft is disk-bound, not CPU-bound |
| prometheus | PROMETHEUS_* | 2G floor | cardinality is THE risk — §3.6 |
| loki/alloy/grafana | per-service | 512M–1G | P10 noise-drop cut Loki volume materially |
| buildkitd | BUILDKIT_* | — | image builds: the throughput king — §3.3 |
| agents (warm ×3) | per agent | — | + dynamic cloud agents (elastic) |

Tiers (single host, everything on):

| Tier | Host | Realistic throughput |
|---|---|---|
| Lab | 8 vCPU / 32 GB | 3–5 concurrent pipelines; GitLab+Sonar+Nexus are the floor |
| Standard | 16 vCPU / 64 GB | 8–12 concurrent pipelines (warm pool + 4–6 cloud agents) |
| Large | 32 vCPU / 128 GB or multi-host | move agents to dedicated hosts (Docker cloud TCP endpoint) — control plane scales horizontally only by splitting agents off |

## 2. Where time goes (typical microservice build, warm cache)

checkout ~10s · unit tests 30–120s (language) · SAST (semgrep, cached rules) 30–90s ·
secrets scan ~10s · dependency scan 1–4 min (OWASP DC NVD mirror is host-updated —
D-16) · container build 1–5 min (layer cache!) · image scan 30–90s (trivy cache) ·
SBOM+sign ~30s · quality gate wait 1–3 min (Sonar CE) · GitOps render+push ~30s ·
ArgoCD sync+health 1–5 min · verify ≤ verify.timeoutSec · smoke ≤ smokeTimeoutSec.
**Cold-cache first build ≈ 2–4×** these numbers (NVD, trivy db, maven/npm/pip/nuget
caches — the named volumes exist exactly for this).

## 3. Bottleneck analysis & tuning

1. **Agent capacity** — first thing to saturate. Symptom: `jenkins_queue_size_value`
   climbs (JenkinsQueueBacklog alert). Tune: warm-pool count (casc/40-nodes.yaml),
   Docker cloud container cap (casc/30-clouds.yaml), agent memory limits.
2. **Sonar CE** — quality-gate wait dominates the tail. Community: single CE
   worker; parallel analyses queue. Symptom: long `quality gate` stage while
   builds are green. Tune: `sonar.ce.workerCount` (licensed) or accept; keep
   branch analysis scoped (D-20 avoids duplicate main/branch work).
3. **BuildKit** — concurrent image builds contend on CPU/disk. Tune:
   BUILDKIT limits, `--cache-from` registry cache (already wired), build
   concurrency cap in the Docker cloud template.
4. **GitLab webhooks → Jenkins** — Sidekiq backlog (GitLabSidekiqBacklog alert)
   delays triggers; the hourly org-folder scan is the safety net (D-22). Tune:
   `sidekiq['max_concurrency']` (set 10 — raise with CPU).
5. **Vault** — raft fsync on writes; AppRole logins are cheap. If ESO sync
   latency grows: check `vault_runtime_alloc_bytes` panel + disk latency.
6. **Prometheus cardinality** — the silent killer. Guardrails already shipped:
   `devsecops-infra` TSDB head-series panel, 15d/30GB retention caps, no
   per-build metrics (build data stays in Jenkins; alerts use gauges/counters).
   If head series > 500k: audit `kubectl`-style label churn in scrape targets.
7. **Loki volume** — Alloy healthcheck drop (D-35) + `max_query_series: 5000`;
   monitor with `devsecops-logs` ingestion panels.

## 4. Load verification procedure (target hardware)

```bash
# 1. baseline: everything healthy, no builds running
./scripts/health-check.sh
# 2. concurrency smoke: trigger N=3 team pipelines simultaneously (three
#    service repos with seeded content — gitlab/scripts/40-seed-repositories.sh)
#    watch: Grafana devsecops-cicd (queue stays ~0 with warm pool ≥ N)
# 3. k6 against the platform edge (Traefik) — read-path sanity, 50 VUs:
k6 run - <<'EOF'
import http from 'k6/http'; import { check } from 'k6';
export const options = { vus: 50, duration: '2m', thresholds: { http_req_failed: ['rate<0.01'], http_req_duration: ['p(95)<800'] } };
export default function () {
  check(http.get(`https://gitlab.${__ENV.DOMAIN}/explore`), { 'gitlab 200': r => r.status === 200 });
  check(http.get(`https://nexus.${__ENV.DOMAIN}/`),          { 'nexus 200':  r => r.status === 200 });
}
EOF
# 4. sustained: one monorepo pipeline every 10 min for 2h; assert:
#    - no JenkinsQueueBacklog / JenkinsExecutorsExhausted alerts
#    - HostMemoryPressure never fires; container restarts = 0 (devsecops-infra)
#    - p99 build duration stable (devsecops-cicd quantiles panel)
# 5. record results → update §1 tier table for YOUR hardware
```

## 5. Tuning checklist (do in this order)

- [ ] DATA_ROOT on SSD/NVMe (raft, TSDB, Loki chunks, blob stores are all fsync-heavy)
- [ ] `vm.swappiness=1` + swap off (architecture §7.3) — GitLab/JVM hate swapping
- [ ] named cache volumes warm (first builds are cold — §2)
- [ ] warm pool ≥ expected concurrent teams; cloud cap ≥ burst
- [ ] PROM_RETENTION_* matched to disk (`df` vs 30GB cap)
- [ ] BACKUP_INTERVAL_HOURS vs RPO table (backup-recovery.md §2)
- [ ] Watchdog + SLO burn alerts routed to a REAL channel (observability.md §6)
