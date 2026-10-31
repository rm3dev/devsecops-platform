#!/usr/bin/env bash
# =============================================================================
# restore.sh — the recovery half of D-37 (Phase 11). Subcommands:
#
#   list                              restic snapshots in the repository
#   files <snapshot> [path…]          restore DATA_ROOT files (all or selected
#                                     paths like data/jenkins-home) — STOPS the
#                                     stack first, restic writes back in place
#   vault-raft <snapshot-file>        restore a raft snapshot (single node):
#                                     vault must be UNSEALED with the ORIGINAL
#                                     unseal keys — see backup-recovery.md §4
#   gitlab <backup-timestamp>         gitlab-backup restore (gitlab-secrets.json
#                                     from the SAME backup era must be in place)
#   sonar-db <dump-file.sql.gz>       replay pg_dumpall into sonarqube-db
#   all <snapshot>                    files + vault-raft + gitlab + sonar-db,
#                                     newest native dumps of the snapshot era
#
# Safety: every destructive path asks for confirmation (FORCE=1 skips), stops
# the affected service first, and never deletes backups. restic restore runs
# inside the `backup` image with DATA_ROOT re-mounted rw at /restore/data so
# snapshot paths (/data/…) land back exactly where they came from.
# =============================================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/lib/common.sh"
load_env

DATA_ROOT="${DATA_ROOT:?DATA_ROOT must be set (.env)}"
REPO="${RESTIC_REPOSITORY:-${RESTIC_REPOSITORY_LOCAL:-/backups/repo}}"
PW_FILE="$ROOT_DIR/secrets/restic_password"

usage() { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
confirm() {
  [[ "${FORCE:-0}" == "1" ]] && return 0
  read -r -p ">> $1 — proceed? [y/N] " a; [[ "$a" == "y" || "$a" == "Y" ]] || die "aborted"
}
restic_run() { ( cd "$ROOT_DIR" && docker compose run --rm -e RESTIC_REPOSITORY="$REPO" --entrypoint restic backup "$@" ); }
stop_svc()  { ( cd "$ROOT_DIR" && docker compose stop "$@" ); }
start_svc() { ( cd "$ROOT_DIR" && docker compose start "$@" ); }

cmd="${1:-help}"; shift || true
case "$cmd" in

list)
  restic_run snapshots --tag devsecops-platform
  ;;

files)
  SNAP="${1:?snapshot id required (see: restore.sh list)}"; shift || true
  confirm "restore files from snapshot $SNAP into $DATA_ROOT (services will be STOPPED)"
  stop_svc jenkins gitlab sonarqube sonarqube-db nexus vault grafana prometheus alertmanager loki alloy || true
  INCLUDES=()
  for p in "$@"; do INCLUDES+=(--include "/data/${p#data/}"); done
  ( cd "$ROOT_DIR" && docker compose run --rm -e RESTIC_REPOSITORY="$REPO" \
      --volume "$DATA_ROOT:/restore/data" --entrypoint restic backup \
      restore "$SNAP" --target /restore ${INCLUDES[@]+"${INCLUDES[@]}"} ) || die "restic restore FAILED"
  log_ok "files restored — review, then start the stack: docker compose --profile all up -d"
  log_info "vault will come up SEALED → unseal with the ORIGINAL keys (backup-recovery.md §4)"
  ;;

vault-raft)
  SNAPF="${1:?raft snapshot file required (data/vault/file/snapshot-*.db)}"
  HOST_PATH="${SNAPF/#data\//"$DATA_ROOT"/}"
  [[ -f "$HOST_PATH" ]] || die "$HOST_PATH not found"
  if [[ -z "${VAULT_ROOT_TOKEN:-}" && -f "$ROOT_DIR/secrets/vault-root.env" ]]; then
    set -a; source "$ROOT_DIR/secrets/vault-root.env"; set +a
  fi
  [[ -n "${VAULT_ROOT_TOKEN:-}" ]] || die "VAULT_ROOT_TOKEN required (secrets/vault-root.env)"
  confirm "restore vault raft from $SNAPF (vault must be UNSEALED with the ORIGINAL unseal keys)"
  CONT_PATH="/vault/file/${HOST_PATH##*/}"
  ( cd "$ROOT_DIR" && docker compose exec -T -e VAULT_TOKEN="$VAULT_ROOT_TOKEN" vault \
      vault operator raft snapshot restore -force "$CONT_PATH" ) || die "raft restore FAILED"
  log_ok "vault raft restored — verify: vault status; then recreate ESO/Jenkins integrations if tokens rotated"
  ;;

gitlab)
  BTS="${1:?backup timestamp required (ls $DATA_ROOT/gitlab/data/backups)}"
  confirm "gitlab-backup restore BACKUP=$BTS (gitlab-secrets.json must match the backup era)"
  stop_svc gitlab || true; start_svc gitlab
  sleep 20
  ( cd "$ROOT_DIR" && docker compose exec -T gitlab gitlab-backup restore BACKUP="$BTS" force=yes ) \
    || die "gitlab restore FAILED"
  log_ok "gitlab restored — verify sign-in + webhook delivery (gitlab/scripts/add-webhook.sh if needed)"
  ;;

sonar-db)
  DUMP="${1:?dump file required (data/backups/native/sonar/sonar-db-*.sql.gz)}"
  HOST_PATH="${DUMP/#data\//"$DATA_ROOT"/}"
  [[ -f "$HOST_PATH" ]] || die "$HOST_PATH not found"
  confirm "replay $HOST_PATH into sonarqube-db (sonarqube will be stopped)"
  stop_svc sonarqube || true
  gunzip -c "$HOST_PATH" | ( cd "$ROOT_DIR" && docker compose exec -T sonarqube-db psql -U sonar -d postgres -q ) \
    || die "psql replay FAILED"
  start_svc sonarqube
  log_ok "sonar db restored — quality gates/history intact after sonarqube is healthy"
  ;;

all)
  SNAP="${1:?snapshot id required}"
  confirm "FULL restore from snapshot $SNAP (stack stop → files → vault → gitlab → sonar)"
  "$0" files "$SNAP"
  log_info "start the stack, unseal vault, then run: $0 vault-raft <newest snapshot-*.db>"
  log_info "after gitlab is up:                                        $0 gitlab <newest backup timestamp>"
  log_info "after sonarqube-db is up:                                 $0 sonar-db <newest dump>"
  ;;

help|*) usage ;;
esac
