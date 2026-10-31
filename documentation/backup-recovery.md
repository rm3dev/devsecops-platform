# Backup, Restore & Disaster Recovery (Phase 11, D-37)

Two backup layers, one restore toolkit:

```
LAYER 1 — component-native CONSISTENT dumps (scripts/native-dumps.sh)
   vault     raft snapshot        data/vault/file/snapshot-<ts>.db          keep 3
   gitlab    gitlab-backup create data/gitlab/data/backups/*_backup.tar     keep 3 (+14d gitlab.rb retention)
   sonar     pg_dumpall --clean   data/backups/native/sonar/*.sql.gz        keep 3
   nexus     db.backup task       data/nexus-data/backups/db/               keep 3

LAYER 2 — restic file-level repository (backup service, 24h loop)
   /data  (minus buildkit-cache, agent-workspaces, docker)
   retention: 7 daily / 4 weekly / 6 monthly, --prune, 5% sampled check per cycle
   default repo: data/backups/repo (LOCAL) → move off-host for production (§7)

RESTORE — scripts/restore.sh {list | files | vault-raft | gitlab | sonar-db | all}
ON-DEMAND — scripts/backup-now.sh  (native dumps + tagged manual snapshot + check)
```

Everything under `DATA_ROOT` (including the native dumps and the default restic
repo) is inside the restic scope — one repository captures config, state and
dumps. `secrets/` (repo root, NOT DATA_ROOT) is deliberately **not** in the
restic scope: it holds live credentials; back it up separately with your
secret-management process (and note the Vault unseal-key custody rule below —
the platform NEVER stores unseal keys).

## 1. Coverage & consistency matrix

| Component | What survives | Native dump | Restic files | Consistency |
|---|---|---|---|---|
| GitLab | repos, issues, MRs, users, PATs, webhooks | ✅ tar | ✅ data/ + config/ (gitlab.rb, **gitlab-secrets.json**) | consistent (STRATEGY=copy) |
| Jenkins | jobs config (JCasC = git anyway), build history, credentials, plugins | — | ✅ jenkins-home | file-level; credentials DB consistent enough when stack stopped at restore |
| Vault | ALL secrets, policies, auth mounts, raft state | ✅ raft snapshot | ✅ vault/file | **snapshot = fully consistent** |
| SonarQube | projects, history, quality gates | ✅ pg_dumpall | ✅ db files + ES index (rebuildable) | consistent replay |
| Nexus | db + blob stores (artifacts/images) | ✅ db.backup | ✅ nexus-data | task-based consistent db; blobs file-level |
| Prometheus/Loki/Grafana | metrics/logs/dashboards | — | ✅ (time-series restorable; dashboards+provisioning are in GIT anyway) | rebuildable — loss acceptable per RPO table |
| Traefik/Alloy config | — | — | in GIT | n/a |

## 2. RPO / RTO (single-node lab defaults; tune via BACKUP_INTERVAL_HOURS)

| Component | RPO | RTO | Notes |
|---|---|---|---|
| Git repos (GitLab) | ≤ 24h (loop) / 0 with off-host git replication | ~30 min | gitlab-backup restore + config |
| Vault | ≤ 24h | ~15 min | raft snapshot restore; **original unseal keys required** |
| Jenkins | ≤ 24h | ~20 min | JCasC/jobs re-apply from git; history from jenkins-home |
| Artifacts (Nexus) | ≤ 24h | ~45 min (size-dependent) | rebuild-from-source is the fallback for images |
| Sonar history | ≤ 24h | ~20 min | re-scan rebuilds current state; history needs the dump |
| Metrics/logs | ≤ 24h | 0 (rebuild) | observability data is explicitly loss-tolerant |

## 3. Scheduling

* The `backup` compose service (profile `backup`) loops restic every
  `BACKUP_INTERVAL_HOURS` (default 24) with forget+prune+check built in.
* Native dumps need host-level docker access → run them from **cron/systemd**:

```bash
# /etc/cron.d/devsecops-backups — daily 02:00, before/with the restic loop
0 2 * * * root cd /opt/devsecops-platform && ./scripts/backup-now.sh >> /var/log/devsecops-backup.log 2>&1
```

`backup-now.sh` = native-dumps + an extra tagged restic snapshot + integrity
check, so the cron path alone is sufficient (the loop service adds cadence
redundancy). Run it manually before ANY upgrade or risky migration.

## 4. Vault: keys, seal, raft restore

* **Key custody**: after `vault operator init -key-shares=5 -key-threshold=3`
  the 5 unseal keys + initial root token go OFF-HOST (sealed envelopes /
  password manager / safe). They are NEVER in DATA_ROOT or the repo — a restic
  restore therefore REQUIRES the original envelopes. Lose 3+ shares and the
  raft data is unrecoverable by design.
* Root token lifecycle: rotate away from the initial token
  (`vault token create -policy=root`, revoke the initial one) — the scripts
  consume `VAULT_ROOT_TOKEN` from `secrets/vault-root.env` (0600, gitignored).
* **Unseal after any restart/restore** (the VaultSealed alert points here):

```bash
docker compose exec vault vault operator unseal   # × 3 shares, wait for sealed=false
```

* **Raft restore** (data loss/corruption; vault must be unsealed first):

```bash
./scripts/restore.sh vault-raft data/vault/file/snapshot-<ts>.db
# → vault operator raft snapshot restore -force /vault/file/snapshot-<ts>.db
```

  Post-restore: policies/mounts/secrets are exactly the snapshot state; rerun
  `vault/scripts/50-jenkins-approle.sh` (fresh secret-id) and the ESO chain
  check (`vault/scripts/30-k8s-auth.sh` is idempotent) because tokens minted
  after the snapshot are gone.
* Audit device: `vault/scripts/60-audit-enable.sh` (fail-closed by design —
  keep disk headroom; HostDiskSpaceLow alert guards it). Audit log ships to
  Loki as `{service="vault-audit"}` via the Alloy file tail.

## 5. Full DR — rebuild on bare metal

```bash
# 0. prerequisites: Docker Engine + compose plugin, same DATA_ROOT path (or edit .env)
# 1. platform code
git clone <this repository> /opt/devsecops-platform && cd /opt/devsecops-platform
cp .env.example .env    # restore YOUR values (domain, sizing, RESTIC_REPOSITORY…)
# 2. secrets: restore from your secret custody (restic does NOT cover secrets/);
#    at minimum: restic_password (repository key!), vault-root.env (root token),
#    the 5 unseal-key envelopes. Bootstrap regenerates anything else.
./scripts/bootstrap.sh                      # dirs, placeholder secrets, internal CA
# 3. pull the restic repository data back
./scripts/restore.sh list                   # pick the snapshot
FORCE=1 ./scripts/restore.sh files <snapshot-id>
# 4. bring the stack up
docker compose --profile all up -d
# 5. vault: unseal with the ORIGINAL keys, then raft-restore if the snapshot era
#    predates the file restore:
docker compose exec vault vault operator unseal   # ×3
./scripts/restore.sh vault-raft data/vault/file/snapshot-<ts>.db
# 6. gitlab (once healthy ~10 min): restore app backup + verify secrets file match
./scripts/restore.sh gitlab <backup-timestamp>
# 7. sonar db, then jenkins recreate (JCasC re-applies everything from git)
./scripts/restore.sh sonar-db data/backups/native/sonar/sonar-db-<ts>.sql.gz
docker compose up -d jenkins
# 8. cluster side (if the K8s cluster is also lost): kubernetes/scripts/00-bootstrap-cluster.sh
#    → ESO resyncs from Vault → ArgoCD re-syncs every app from the gitops repo
# 9. validate: installation.md §16 checklist + observability.md §7 (Watchdog firing)
```

## 6. Component restores (single-service incidents)

| Need | Command |
|---|---|
| lost Jenkins credentials/config | `restore.sh files <snap> data/jenkins-home` → `docker compose up -d jenkins` |
| corrupted GitLab repo(s) | `restore.sh gitlab <ts>` (full-app; per-repo: extract from the tar's `repositories/`) |
| Sonar history lost | `restore.sh sonar-db <dump>` (stop sonarqube first — script does it) |
| Nexus db corruption | stop nexus → replace `data/nexus-data/db` from `backups/db/<ts>/` → start |
| Grafana/dashboards | nothing to do — provisioning + dashboards live in git; volume is disposable |
| one file/directory | `restic restore <snap> --target /tmp/x --include /data/path` via compose run (see restore.sh `files` for the mount pattern) |

## 7. Off-host repository + password rotation

```bash
# .env — point BOTH the loop service and backup-now.sh at the off-host repo:
RESTIC_REPOSITORY=sftp:backup@backup.internal:/srv/restic/devsecops   # or rest:https://…, s3:…
# ssh key for the sftp user: mount into the backup service (compose override),
# restricted to restic-only access (rssh/git-shell or a forced command).
```

* A LOCAL repo (`data/backups/repo`) protects against file-level mistakes, not
  against host loss — production sites MUST set `RESTIC_REPOSITORY` off-host.
* **restic password rotation**: `restic copy` to a new repo initialized with a
  new password (`secrets/restic_password`), verify snapshots, switch `.env`,
  `restic forget --prune` the old repo. Never edit the password file in place —
  the repository key is derived from it; losing it loses ALL snapshots.

## 8. Restore drills (quarterly — the only backup that counts)

1. `backup-now.sh` → note the snapshot id.
2. On a scratch host (or stopped stack): full §5 walkthrough.
3. Assert: GitLab sign-in + one clone; Jenkins login + one build green;
   Vault `kv get secret/platform/notifications`; Sonar project history present;
   Nexus `docker pull` of a backed-up image digest.
4. Record duration → update the RTO table (§2). File any gap as a platform issue.

## 9. Acceptance mapping

- [x] consistent native dumps for all four stateful components (script + staging + pruning)
- [x] restic layer with retention, prune, sampled integrity check, manual on-demand path
- [x] single restore toolkit covering files/vault/gitlab/sonar + full-DR orchestration
- [x] unseal-key custody + raft-restore semantics documented (alerts link here)
- [x] off-host repo + password rotation runbooks
- [ ] drill executed on target hardware (schedule it — §8)
