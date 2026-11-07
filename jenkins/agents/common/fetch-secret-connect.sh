#!/usr/bin/env bash
# =============================================================================
# Warm-agent entrypoint (Phase 3)
#
# Inbound (JNLP4) agents need a per-node secret that only the controller knows.
# This script waits for the controller, verifies the node object exists (JCasC
# creates it at startup), fetches the secret via the authenticated JNLP
# endpoint and then execs the stock `jenkins-agent` launcher from the base
# image. Credentials come from secrets/jenkins.env (env_file) — never baked
# into images.
# =============================================================================
set -euo pipefail

: "${DEVSECOPS_AGENT_NAME:?DEVSECOPS_AGENT_NAME must be set (compose service environment)}"
: "${JENKINS_ADMIN_USER:?JENKINS_ADMIN_USER must be set (secrets/jenkins.env)}"
: "${JENKINS_ADMIN_PASSWORD:?JENKINS_ADMIN_PASSWORD must be set (secrets/jenkins.env)}"
JENKINS_INTERNAL_URL="${JENKINS_INTERNAL_URL:-http://jenkins:8080}"
AUTH=(-u "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}")

# GitLab advertises its public HTTPS clone URL, which is unreachable from the
# isolated agents plane. Rewrite that prefix to the GitLab service DNS name; the
# group-scoped read-only checkout credential is still supplied by Jenkins.
if [[ -n "${PLATFORM_DOMAIN:-}" ]] && command -v git >/dev/null 2>&1; then
  git config --global --replace-all \
    "url.http://gitlab/.insteadOf" "https://gitlab.${PLATFORM_DOMAIN}/"
fi

log() { echo "[agent:${DEVSECOPS_AGENT_NAME}] $*"; }

log "waiting for Jenkins controller at ${JENKINS_INTERNAL_URL} …"
until curl -fsS --max-time 10 "${AUTH[@]}" -o /dev/null "${JENKINS_INTERNAL_URL}/login"; do
  sleep 10
done

log "waiting for node '${DEVSECOPS_AGENT_NAME}' to be registered (JCasC 40-nodes.yaml) …"
until curl -fsS --max-time 10 "${AUTH[@]}" -o /dev/null "${JENKINS_INTERNAL_URL}/computer/${DEVSECOPS_AGENT_NAME}/api/json"; do
  sleep 10
done

log "fetching agent secret …"
JNLP="$(curl -fsS --max-time 15 "${AUTH[@]}" "${JENKINS_INTERNAL_URL}/computer/${DEVSECOPS_AGENT_NAME}/jenkins-agent.jnlp")"
SECRET="$(grep -oE '<argument>[^<]+</argument>' <<< "$JNLP" | head -1 | sed -E 's|</?argument>||g')"
if [[ -z "$SECRET" ]]; then
  log "ERROR: could not extract agent secret — is the node configured as inbound (JNLP)?"
  exit 1
fi

log "connecting (workDir=/home/jenkins/agent) …"
exec jenkins-agent \
  -url "${JENKINS_INTERNAL_URL}/" \
  -name "${DEVSECOPS_AGENT_NAME}" \
  -secret "${SECRET}" \
  -workDir /home/jenkins/agent
