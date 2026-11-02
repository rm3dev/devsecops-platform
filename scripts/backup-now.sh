#!/usr/bin/env bash
# =============================================================================
# backup-now.sh — on-demand FULL backup cycle (Phase 11, D-37):
#   1. scripts/native-dumps.sh   (component-consistent dumps → DATA_ROOT)
#   2. one-shot restic snapshot  (same repository/excludes as the `backup`
#      service loop, tagged manual-<ts> so it is distinguishable in `restic
#      snapshots`; retention stays owned by the loop)
#   3. sampled integrity check (restic check --read-data-subset=5%)
#
# Use it: before upgrades, before risky migrations, ad-hoc ("backup NOW"),
# or from cron/systemd at the same cadence as BACKUP_INTERVAL_HOURS.
# Off-host repositories: set RESTIC_REPOSITORY in .env to e.g.
#   sftp:backup@backup.internal:/srv/restic/devsecops   or   rest:https://…
# (the `backup` service and this script both honor it — see backup-recovery.md §7)
# =============================================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/lib/common.sh"
load_env

TS="$(date -u +%Y%m%dT%H%M%S)"
REPO="${RESTIC_REPOSITORY:-${RESTIC_REPOSITORY_LOCAL:-/backups/repo}}"
PW_FILE="$ROOT_DIR/secrets/restic_password"
[[ -f "$PW_FILE" ]] || die "missing $PW_FILE — run scripts/bootstrap.sh first"

# --- 1. native dumps (failures warn but do not abort the file-level snapshot) -----
log_info "staging component-native dumps…"
"$ROOT_DIR/scripts/native-dumps.sh" || log_warn "native-dumps reported failures — continuing with the restic snapshot"

# --- 2. one-shot restic snapshot ----------------------------------------------------
log_info "restic snapshot → $REPO (tag manual-$TS)"
( cd "$ROOT_DIR" && docker compose run --rm \
    -e RESTIC_REPOSITORY="$REPO" \
    --entrypoint restic backup \
    backup /data \
    --exclude /data/buildkit-cache --exclude /data/agent-workspaces --exclude /data/docker \
    --tag devsecops-platform --tag "manual-$TS" ) \
  || die "restic snapshot FAILED"
log_ok "snapshot complete"

# --- 3. sampled integrity check ------------------------------------------------------
( cd "$ROOT_DIR" && docker compose run --rm -e RESTIC_REPOSITORY="$REPO" --entrypoint restic backup \
    check --read-data-subset=5% ) \
  && log_ok "integrity check passed (5% sample)" \
  || log_warn "integrity check reported problems — run 'restic check --read-data' manually"

log_info "list snapshots: $(basename "$0") is one-shot; use scripts/restore.sh list"
