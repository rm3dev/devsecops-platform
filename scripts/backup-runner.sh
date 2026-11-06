#!/bin/sh
# =============================================================================
# Backup runner (Phase 2 baseline) — restic file-level backup of DATA_ROOT.
#
# Scope now:      consistent-enough file backup of configuration + small state,
#                 excluding caches and high-churn data (BACKUP_EXCLUDES).
# Scope Phase 11: component-native consistent dumps (gitlab-backup, pg_dump,
#                 vault raft snapshot, Nexus backup task) staged into DATA_ROOT
#                 before each restic run + off-host RESTIC_REPOSITORY.
#
# Runs inside the `backup` compose service (profile: backup).
# =============================================================================
set -eu

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY must be set}"
: "${RESTIC_PASSWORD_FILE:?RESTIC_PASSWORD_FILE must be set}"
INTERVAL_HOURS="${BACKUP_INTERVAL_HOURS:-24}"
KEEP_DAILY="${BACKUP_KEEP_DAILY:-7}"
KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${BACKUP_KEEP_MONTHLY:-6}"

log() { echo "[backup-runner $(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# Build --exclude arguments from comma-separated list
EXCLUDE_ARGS=""
if [ -n "${BACKUP_EXCLUDES:-}" ]; then
  OLD_IFS="$IFS"; IFS=','
  for pattern in $BACKUP_EXCLUDES; do
    EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude $pattern"
  done
  IFS="$OLD_IFS"
fi

init_repo() {
  if restic snapshots >/dev/null 2>&1; then
    log "repository already initialized at ${RESTIC_REPOSITORY}"
  else
    log "initializing restic repository at ${RESTIC_REPOSITORY}"
    restic init
  fi
}

run_backup() {
  log "starting backup of /data (excludes: ${BACKUP_EXCLUDES:-none})"
  # shellcheck disable=SC2086
  restic backup --host devsecops-platform /data $EXCLUDE_ARGS \
    --tag devsecops-platform \
    --tag "host-$(hostname)"
  log "applying retention: daily=${KEEP_DAILY} weekly=${KEEP_WEEKLY} monthly=${KEEP_MONTHLY}"
  restic forget \
    --keep-daily "$KEEP_DAILY" \
    --keep-weekly "$KEEP_WEEKLY" \
    --keep-monthly "$KEEP_MONTHLY" \
    --prune
  log "verifying repository integrity (sampled)"
  restic check --read-data-subset=5%
  log "backup cycle complete"
}

init_repo

while true; do
  if run_backup; then
    log "next cycle in ${INTERVAL_HOURS}h"
  else
    log "ERROR: backup cycle failed — will retry next interval"
  fi
  sleep $((INTERVAL_HOURS * 3600))
done
