#!/usr/bin/env bash
# =============================================================================
# native-dumps.sh — component-native CONSISTENT dumps staged into DATA_ROOT
# (Phase 11, D-37). Run BEFORE/alongside the restic cycle (cron/systemd timer
# or scripts/backup-now.sh) so the file-level restic backup captures
# application-consistent snapshots, not just live files:
#
#   vault    raft snapshot      → $DATA_ROOT/vault/file/snapshot-<ts>.db   (keep 3)
#   gitlab   gitlab-backup      → $DATA_ROOT/gitlab/data/backups/*.tar     (keep 3)
#   sonarqube pg_dumpall        → $DATA_ROOT/backups/native/sonar/*.sql.gz (keep 3)
#   nexus    db.backup task     → $DATA_ROOT/nexus-data/backups/db/        (keep 3)
#
# Every component is OPTIONAL: not-running / not-configured pieces are skipped
# with a warning so the remaining dumps still land (partial > nothing).
# Full restore procedures: documentation/backup-recovery.md.
# Requires: docker compose. Root token (vault) / admin pw (nexus) from secrets/.
# =============================================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/lib/common.sh"
load_env
# common.sh forces 'set -Eeuo pipefail'; this script must NOT die mid-sequence
# (every component is optional, partial dumps beat nothing) -> drop errexit.
set +e

DATA_ROOT="${DATA_ROOT:?DATA_ROOT must be set (.env)}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
STAGE="$DATA_ROOT/backups/native"
mkdir -p "$STAGE/sonar"
FAILURES=0

running() { ( cd "$ROOT_DIR" && docker compose ps --status running --services 2>/dev/null | grep -qx "$1" ); }
prune_keep() { # dir glob keep — delete oldest beyond N
  local dir="$1" glob="$2" keep="$3" f
  mapfile -t f < <(ls -1t "$dir"/$glob 2>/dev/null | tail -n +$((keep + 1)))
  if [[ ${#f[@]} -gt 0 ]]; then
    rm -f "${f[@]}"
    log_info "pruned ${#f[@]} old dump(s) in $dir"
  fi
  return 0   # never hand the caller a non-zero status just because there was nothing to prune
}

# --- 1. Vault raft snapshot -----------------------------------------------------
if running vault; then
  if [[ -z "${VAULT_ROOT_TOKEN:-}" && -f "$ROOT_DIR/secrets/vault-root.env" ]]; then
    set -a; source "$ROOT_DIR/secrets/vault-root.env"; set +a
  fi
  if [[ -n "${VAULT_ROOT_TOKEN:-}" ]]; then
    if ( cd "$ROOT_DIR" && docker compose exec -T -e VAULT_TOKEN="$VAULT_ROOT_TOKEN" vault \
         vault operator raft snapshot save "/vault/file/snapshot-${TS}.db" ); then
      log_ok "vault raft snapshot: vault/file/snapshot-${TS}.db"
      prune_keep "$DATA_ROOT/vault/file" "snapshot-*.db" 3
    else
      log_error "vault raft snapshot FAILED (sealed?)"; FAILURES=$((FAILURES+1))
    fi
  else
    log_warn "vault running but VAULT_ROOT_TOKEN unavailable — raft snapshot skipped"
  fi
else
  log_warn "vault not running — raft snapshot skipped"
fi

# --- 2. GitLab application backup ------------------------------------------------
if running gitlab; then
  if ( cd "$ROOT_DIR" && docker compose exec -T gitlab gitlab-backup create STRATEGY=copy GZIP_PARALLEL=1 CRON=1 ); then
    log_ok "gitlab backup created (gitlab/data/backups/, 14d retention via gitlab.rb)"
    prune_keep "$DATA_ROOT/gitlab/data/backups" "*_gitlab_backup.tar" 3
  else
    log_error "gitlab-backup FAILED"; FAILURES=$((FAILURES+1))
  fi
else
  log_warn "gitlab not running — application backup skipped"
fi

# --- 3. SonarQube database (pg_dumpall, consistent via --clean replay) ------------
if running sonarqube-db; then
  if ( cd "$ROOT_DIR" && docker compose exec -T sonarqube-db pg_dumpall -U sonar --clean ) \
       | gzip > "$STAGE/sonar/sonar-db-${TS}.sql.gz" && [[ -s "$STAGE/sonar/sonar-db-${TS}.sql.gz" ]]; then
    log_ok "sonar db dump: backups/native/sonar/sonar-db-${TS}.sql.gz"
    prune_keep "$STAGE/sonar" "sonar-db-*.sql.gz" 3
  else
    rm -f "$STAGE/sonar/sonar-db-${TS}.sql.gz"
    log_error "sonar pg_dumpall FAILED"; FAILURES=$((FAILURES+1))
  fi
else
  log_warn "sonarqube-db not running — db dump skipped"
fi

# --- 4. Nexus database backup task --------------------------------------------------
if running nexus; then
  [[ -f "$ROOT_DIR/secrets/nexus.env" ]] && { set -a; source "$ROOT_DIR/secrets/nexus.env"; set +a; }
  if [[ -n "${NEXUS_ADMIN_PASSWORD:-}" ]]; then
    NX="http://localhost:8081/service/rest/v1"
    nxc() { ( cd "$ROOT_DIR" && docker compose exec -T nexus curl -sS -m 300 -u "admin:${NEXUS_ADMIN_PASSWORD}" "$@" ); }
    task_id="$(nxc "$NX/tasks" | jq -r --arg n "platform-dr-db-backup" '.items[] | select(.name==$n) | .id' | head -1)"
    if [[ -z "$task_id" ]]; then
      task_id="$(nxc -X POST "$NX/tasks" -H 'Content-Type: application/json' \
        -d '{"name":"platform-dr-db-backup","typeId":"db.backup","schedule":null,"attributes":{"location":"/nexus-data/backups/db"}}' \
        | jq -r '.id // empty')"
      [[ -n "$task_id" ]] && log_ok "nexus db.backup task created ($task_id)"
    fi
    if [[ -n "$task_id" ]]; then
      nxc -X POST "$NX/tasks/$task_id/run" >/dev/null
      for _ in $(seq 1 60); do   # ≤10 min
        st="$(nxc "$NX/tasks/$task_id" | jq -r '.lastRunResult // "PENDING"')"
        [[ "$st" == "OK" ]] && break
        [[ "$st" != "PENDING" && "$st" != "null" && -n "$st" && "$st" != "RUNNING" ]] && break
        sleep 10
      done
      if [[ "$st" == "OK" ]]; then
        log_ok "nexus db backup complete (nexus-data/backups/db/)"
        prune_keep "$DATA_ROOT/nexus-data/backups/db" "db-*" 3
      else
        log_error "nexus db.backup lastRunResult=${st:-unknown}"; FAILURES=$((FAILURES+1))
      fi
    else
      log_error "could not create/find the nexus db.backup task"; FAILURES=$((FAILURES+1))
    fi
  else
    log_warn "NEXUS_ADMIN_PASSWORD unavailable — nexus db backup skipped"
  fi
else
  log_warn "nexus not running — db backup skipped"
fi

echo
if [[ $FAILURES -eq 0 ]]; then
  log_ok "native dumps complete (ts=${TS}) — restic picks everything up from DATA_ROOT"
else
  log_error "$FAILURES component dump(s) FAILED — restic will still capture the rest; investigate before the next cycle"
  exit 1
fi
