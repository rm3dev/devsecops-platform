#!/usr/bin/env bash
# =============================================================================
# GitLab API helper library (Phase 4)
#
# All API calls execute INSIDE the gitlab container against
# http://localhost/api/v4 — no host TLS trust, no DNS dependency, and the
# GitLab port is never exposed (architecture §5). Requires: jq on the host.
#
# Sourced by the scripts in this directory AFTER lib/common.sh (ROOT_DIR,
# load_env, compose, log_* are expected to exist).
# =============================================================================

GITLAB_API="http://localhost/api/v4"
GITLAB_RAILS_RUNNER=(gitlab-rails runner)

gl_compose_exec() { # runs a command inside the gitlab container
  ( cd "$ROOT_DIR" && docker compose -f docker-compose.yml exec -T gitlab "$@" )
}

gl_api() { # METHOD /path [json-body]  → response body on stdout
  local method="$1" path="$2" data="${3:-}"
  : "${GITLAB_ROOT_TOKEN:?GITLAB_ROOT_TOKEN missing in secrets/gitlab.env — run 10-create-root-token.sh}"
  local curl_args=(curl -sS --max-time 60 -X "$method"
                   -H "PRIVATE-TOKEN: ${GITLAB_ROOT_TOKEN}"
                   -H "Content-Type: application/json")
  [[ -n "$data" ]] && curl_args+=(--data "$data")
  gl_compose_exec "${curl_args[@]}" "${GITLAB_API}${path}"
}

gl_api_rc() { # like gl_api but prints "HTTPCODE<newline>BODY"
  local method="$1" path="$2" data="${3:-}"
  : "${GITLAB_ROOT_TOKEN:?GITLAB_ROOT_TOKEN missing — run 10-create-root-token.sh}"
  local curl_args=(curl -sS --max-time 60 -o /tmp/gl-body -w '%{http_code}' -X "$method"
                   -H "PRIVATE-TOKEN: ${GITLAB_ROOT_TOKEN}"
                   -H "Content-Type: application/json")
  [[ -n "$data" ]] && curl_args+=(--data "$data")
  local code
  code="$(gl_compose_exec "${curl_args[@]}" "${GITLAB_API}${path}")"
  echo "$code"
  gl_compose_exec cat /tmp/gl-body
}

# uri_encode + append_secret provided by scripts/lib/common.sh

load_gitlab_secrets() {
  if [[ -f "$ROOT_DIR/secrets/gitlab.env" ]]; then
    set -a; source "$ROOT_DIR/secrets/gitlab.env"; set +a
  fi
  if [[ -f "$ROOT_DIR/secrets/gitlab-jenkins.env" ]]; then
    set -a; source "$ROOT_DIR/secrets/gitlab-jenkins.env"; set +a
  fi
}

wait_for_gitlab() {
  log_info "waiting for GitLab to become healthy (first boot can take 5–10 minutes)…"
  local deadline=$(( $(date +%s) + 900 ))
  until [[ "$(gl_compose_exec curl -sS -m 5 http://localhost/-/health 2>/dev/null || true)" == "GitLab OK" ]]; do
    if [[ $(date +%s) -ge $deadline ]]; then
      die "GitLab did not become healthy within 15 minutes — check: docker compose logs gitlab"
    fi
    sleep 15
  done
  log_ok "GitLab is healthy"
}
