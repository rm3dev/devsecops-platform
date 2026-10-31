#!/usr/bin/env bash
# =============================================================================
# Shared helpers for platform scripts (Phase 2)
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Allow being sourced from both scripts/ and scripts/lib/
if [[ "$(basename "$SCRIPT_DIR")" == "lib" ]]; then
  SCRIPTS_DIR="$(dirname "$SCRIPT_DIR")"
else
  SCRIPTS_DIR="$SCRIPT_DIR"
fi
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''
fi

log_info()  { echo "${C_BLUE}[INFO]${C_RESET}  $*"; }
log_ok()    { echo "${C_GREEN}[ OK ]${C_RESET}  $*"; }
log_warn()  { echo "${C_YELLOW}[WARN]${C_RESET}  $*" >&2; }
log_error() { echo "${C_RED}[FAIL]${C_RESET}  $*" >&2; }
die()       { log_error "$*"; exit 1; }

require_cmd() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
  done
}

# Load .env if present (values become shell variables AND are available for
# docker compose interpolation because compose reads .env itself).
load_env() {
  if [[ -f "$ROOT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$ROOT_DIR/.env"
    set +a
  else
    log_warn ".env not found in $ROOT_DIR (copy .env.example → .env first)"
  fi
  PLATFORM_DOMAIN="${PLATFORM_DOMAIN:-devsecops.internal}"
  DATA_ROOT="${DATA_ROOT:-/mnt/data/devsecops}"
}

# Compose invocation always uses explicit -f so that docker-compose.override.yml
# (developer direct-port mapping) is NOT silently applied to managed rollouts.
COMPOSE_BASE=(-f docker-compose.yml)
compose() {
  ( cd "$ROOT_DIR" && docker compose "${COMPOSE_BASE[@]}" "$@" )
}

# Sudo wrapper: use sudo when not root and sudo is available
maybe_sudo() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "Need root privileges (no sudo available) for: $*"
  fi
}

gen_secret() { openssl rand -hex 16; }

uri_encode() { jq -rn --arg x "$1" '$x | @uri'; }

append_secret() { # file, KEY=VALUE — replace existing key or append; keeps 0600
  local file="$1" kv="$2" key="${2%%=*}"
  touch "$file"; chmod 600 "$file"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${kv}|" "$file"
  else
    echo "$kv" >> "$file"
  fi
}
