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

: "${AGENT_NAME:?AGENT_NAME must be set (compose service environment)}"
: "${JENKINS_ADMIN_USER:?JENKINS_ADMIN_USER must be set (secrets/jenkins.env)}"
: "${JENKINS_ADMIN_PASSWORD:?JENKINS_ADMIN_PASSWORD must be set (secrets/jenkins.env)}"
JENKINS_INTERNAL_URL="${JENKINS_INTERNAL_URL:-http://jenkins:8080}"
AUTH=(-u "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}")

log() { echo "[agent:${AGENT_NAME}] $*"; }

log "waiting for Jenkins controller at ${JENKINS_INTERNAL_URL} …"
until curl -fsS --max-time 10 "${AUTH[@]}" -o /dev/null "${JENKINS_INTERNAL_URL}/login"; do
  sleep 10
done

log "waiting for node '${AGENT_NAME}' to be registered (JCasC 40-nodes.yaml) …"
until curl -fsS --max-time 10 "${AUTH[@]}" -o /dev/null "${JENKINS_INTERNAL_URL}/computer/${AGENT_NAME}/api/json"; do
  sleep 10
done

log "fetching agent secret …"
JNLP="$(curl -fsS --max-time 15 "${AUTH[@]}" "${JENKINS_INTERNAL_URL}/computer/${AGENT_NAME}/jenkins-agent.jnlp")"
SECRET="$(grep -oE '<argument>[^<]+</argument>' <<< "$JNLP" | head -1 | sed -E 's|</?argument>||g')"
if [[ -z "$SECRET" ]]; then
  log "ERROR: could not extract agent secret — is the node configured as inbound (JNLP)?"
  exit 1
fi

log "connecting (workDir=/home/jenkins/agent) …"
exec jenkins-agent \
  -url "${JENKINS_INTERNAL_URL}/" \
  -name "${AGENT_NAME}" \
  -secret "${SECRET}" \
  -workDir /home/jenkins/agent
