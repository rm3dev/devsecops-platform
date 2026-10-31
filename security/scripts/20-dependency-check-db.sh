#!/usr/bin/env bash
# =============================================================================
# 20-dependency-check-db.sh — HOST-SIDE NVD/vulnerability-data mirror update
# for OWASP Dependency-Check (Phase 7, D-24).
#
# Agents have no internet (D-16), so the NVD mirror is maintained here — on
# the host, which HAS egress — and shared with agent-security via the compose
# volume ${DATA_ROOT}/security/dependency-check → /owasp-dc. Pipeline scans
# then run fully offline: dependency-check.sh --noupdate --dataDir /owasp-dc.
#
#   ./security/scripts/20-dependency-check-db.sh [--full]
#
#   --full  also refreshes hosted-suppressions/retireJS caches (default: NVD +
#           core feeds only, which is what --updateonly does)
#
# FIRST RUN takes a long time without an NVD API key (rate-limited downloads);
# set NVD_API_KEY in .env (free at nvd.nist.gov) — with a key it's minutes.
# Schedule nightly, e.g. systemd timer or cron:
#   0 3 * * * cd /opt/devsecops-platform && ./security/scripts/20-dependency-check-db.sh >> /var/log/dc-update.log 2>&1
#
# The image tag MUST equal the CLI version baked into agent-security
# (DEPENDENCY_CHECK_VERSION in .env / Dockerfile ARG) — H2 schema compatibility.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
load_env
require_cmd docker

DC_VERSION="${DEPENDENCY_CHECK_VERSION:-12.1.0}"
IMAGE="owasp/dependency-check:${DC_VERSION}"
DATA_DIR="$DATA_ROOT/security/dependency-check"

[[ -d "$DATA_DIR" ]] || die "${DATA_DIR} missing — run scripts/bootstrap.sh first"
# The updater container runs as root and must leave files writable by the agent (uid 1000)
log_info "pulling ${IMAGE} (same version as the agent CLI: ${DC_VERSION})…"
docker pull "$IMAGE" || die "docker pull ${IMAGE} failed"

NVD_ARGS=()
if [[ -n "${NVD_API_KEY:-}" ]]; then
  NVD_ARGS=(--nvdApiKey "$NVD_API_KEY")
  log_info "using NVD API key from .env (fast mirror sync)"
else
  log_warn "NVD_API_KEY not set — first sync may take HOURS (NVD rate limiting). Request a free key: https://nvd.nist.gov/developers/request-an-api-key"
fi

log_info "updating vulnerability data (this can take a while)…"
docker run --rm \
  -v "$DATA_DIR":/usr/share/dependency-check/data \
  --entrypoint /usr/share/dependency-check/bin/dependency-check.sh \
  "$IMAGE" --updateonly "${NVD_ARGS[@]}" \
  || die "dependency-check --updateonly failed (see output above)"

# normalize ownership so agent-security (uid 1000) can open/lock the H2 store
maybe_sudo chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true

if [[ -f "$DATA_DIR/odc.mv.db" ]]; then
  SIZE="$(du -sh "$DATA_DIR" | cut -f1)"
  log_ok "NVD mirror updated → ${DATA_DIR} (${SIZE})"
  log_info "pipeline scans now run offline: dependency-check.sh --noupdate --dataDir /owasp-dc"
else
  die "update finished but odc.mv.db is missing in ${DATA_DIR} — inspect the container output"
fi
