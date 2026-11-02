#!/usr/bin/env bash
# =============================================================================
# cleanup.sh — controlled teardown (Phase 2)
#
#   ./scripts/cleanup.sh               # stop & remove containers + networks
#   ./scripts/cleanup.sh --images      # … also remove the pinned images
#   ./scripts/cleanup.sh --purge       # … ALSO delete ALL persistent data
#                                      #   (DATA_ROOT, secrets, TLS material)
#   ./scripts/cleanup.sh --purge --yes # non-interactive (automation only)
#
# --purge is irreversible: it destroys repositories, artifacts, quality history
# and secrets. Take a backup first (backups/ or Phase 11 restore procedure).
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_env

REMOVE_IMAGES=0; PURGE=0; ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --images) REMOVE_IMAGES=1 ;;
    --purge)  PURGE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  read -r -p "$1 [type 'yes' to confirm] " answer
  [[ "$answer" == "yes" ]] || { log_info "aborted"; exit 1; }
}

log_info "Stopping platform (all profiles)…"
( cd "$ROOT_DIR" && docker compose "${COMPOSE_BASE[@]}" --profile all down \
    --remove-orphans $([[ $REMOVE_IMAGES -eq 1 ]] && echo --rmi all) ) || true

if [[ $PURGE -eq 1 ]]; then
  confirm "PURGE will permanently delete: ${DATA_ROOT} (git repos, images, DBs), ./secrets, TLS certificates, generated proxy config."
  log_warn "Purging persistent data…"
  maybe_sudo rm -rf "${DATA_ROOT:?}/gitlab" "${DATA_ROOT:?}/jenkins-home" \
    "${DATA_ROOT:?}/agent-workspaces" "${DATA_ROOT:?}/sonarqube" "${DATA_ROOT:?}/sonarqube-db" \
    "${DATA_ROOT:?}/nexus-data" "${DATA_ROOT:?}/vault" "${DATA_ROOT:?}/prometheus-data" \
    "${DATA_ROOT:?}/alertmanager-data" "${DATA_ROOT:?}/loki-data" "${DATA_ROOT:?}/alloy-data" \
    "${DATA_ROOT:?}/grafana-data" "${DATA_ROOT:?}/buildkit-cache" "${DATA_ROOT:?}/backups"
  rm -rf "$ROOT_DIR/secrets"
  rm -f  "$ROOT_DIR"/reverse-proxy/certificates/*.crt "$ROOT_DIR"/reverse-proxy/certificates/*.key \
         "$ROOT_DIR"/reverse-proxy/certificates/*.srl
  rm -f  "$ROOT_DIR/reverse-proxy/configuration/dynamic/dynamic.yml"
  log_ok "Purge complete — platform can be re-bootstrapped from scratch"
else
  log_ok "Containers and networks removed (persistent data preserved in ${DATA_ROOT})"
fi
