#!/usr/bin/env bash
# =============================================================================
# build-images.sh — build custom platform images (Phase 3)
#
#   ./scripts/build-images.sh                # controller + all 7 agents
#   ./scripts/build-images.sh --controller   # only the Jenkins controller
#   ./scripts/build-images.sh --agents       # only the agent images
#   ./scripts/build-images.sh --agent python # only one agent
#
# Image naming contract (used by compose + JCasC cloud templates):
#   controller : ${JENKINS_IMAGE_OVERRIDE}:${JENKINS_VERSION}
#   agents     : devsecops/agent-<name>:${AGENT_IMAGE_TAG}
#
# All base images and tool downloads are pinned inside the Dockerfiles
# (versions verified 2026-10-30). BuildKit is used for layer caching.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_env
require_cmd docker

BUILD_CONTROLLER=1; BUILD_AGENTS=1; ONLY_AGENT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --controller) BUILD_CONTROLLER=1; BUILD_AGENTS=0 ;;
    --agents)     BUILD_CONTROLLER=0; BUILD_AGENTS=1 ;;
    --agent)      BUILD_CONTROLLER=0; BUILD_AGENTS=1; ONLY_AGENT="${2:?--agent requires a name}"; shift ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            die "Unknown argument: $1" ;;
  esac
  shift
done

INBOUND_AGENT_IMAGE="jenkins/inbound-agent:${INBOUND_AGENT_VERSION:-3395.v6e5377b_0fb_3c-3-jdk21}"
AGENT_IMAGE_TAG="${AGENT_IMAGE_TAG:-1.0.0}"
export DOCKER_BUILDKIT=1

if [[ $BUILD_CONTROLLER -eq 1 ]]; then
  if [[ -z "${JENKINS_IMAGE_OVERRIDE:-}" ]]; then
    log_warn "JENKINS_IMAGE_OVERRIDE is empty — controller image build skipped (official image will be used)"
  else
    log_info "Building controller image ${JENKINS_IMAGE_OVERRIDE}:${JENKINS_VERSION}"
    docker build \
      --build-arg BASE_IMAGE="jenkins/jenkins:${JENKINS_VERSION}" \
      -t "${JENKINS_IMAGE_OVERRIDE}:${JENKINS_VERSION}" \
      -f "$ROOT_DIR/jenkins/Dockerfile" \
      "$ROOT_DIR/jenkins"
    log_ok "controller image built"
  fi
fi

AGENTS=(general python security java-maven java-gradle dotnet nodejs)
if [[ $BUILD_AGENTS -eq 1 ]]; then
  # agent-general bakes the platform CA for registry.<domain> TLS trust (D-23)
  if [[ -f "$ROOT_DIR/reverse-proxy/certificates/ca.crt" ]]; then
    cp "$ROOT_DIR/reverse-proxy/certificates/ca.crt" "$ROOT_DIR/jenkins/agents/common/platform-ca.crt"
    log_info "platform CA staged into agent build context"
  else
    die "reverse-proxy/certificates/ca.crt missing — run scripts/bootstrap.sh (TLS section) before building agent images"
  fi
  for agent in "${AGENTS[@]}"; do
    if [[ -n "$ONLY_AGENT" && "$ONLY_AGENT" != "$agent" ]]; then continue; fi
    [[ -d "$ROOT_DIR/jenkins/agents/$agent" ]] || die "agent directory missing: jenkins/agents/$agent"
    log_info "Building agent image devsecops/agent-${agent}:${AGENT_IMAGE_TAG}"
    docker build \
      --build-arg INBOUND_AGENT_IMAGE="${INBOUND_AGENT_IMAGE}" \
      -t "devsecops/agent-${agent}:${AGENT_IMAGE_TAG}" \
      -f "$ROOT_DIR/jenkins/agents/${agent}/Dockerfile" \
      "$ROOT_DIR/jenkins/agents"
    log_ok "agent-${agent} built"
  done
fi

log_info "Done. Start/refresh with: ./scripts/bootstrap.sh --with-agents"
