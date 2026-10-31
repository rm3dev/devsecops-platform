# =============================================================================
# agent-nodejs — Node.js builds (npm/pnpm/yarn via corepack), React/Angular/Vue
# Node 22 LTS multi-stage copy from the official image; package managers are
# activated through corepack (pinned by each project's packageManager field).
# =============================================================================
ARG INBOUND_AGENT_IMAGE=jenkins/inbound-agent:3395.v6e5377b_0fb_3c-3-jdk21
ARG NODE_IMAGE=node:22.23.4-bookworm-slim
FROM ${NODE_IMAGE} AS node-runtime

FROM ${INBOUND_AGENT_IMAGE}

ARG SONAR_SCANNER_VERSION=8.3.0.16463

USER root
COPY common/fetch-secret-connect.sh /usr/local/bin/fetch-secret-connect.sh
# Node.js 22 toolchain (merged into /usr/local — inbound-agent scripts kept)
COPY --from=node-runtime /usr/local /usr/local

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates git unzip zip python3 make g++; \
    corepack enable; \
    curl -fsSL -o /tmp/sonar-scanner.zip \
      "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip"; \
    unzip -q /tmp/sonar-scanner.zip -d /opt; \
    mv /opt/sonar-scanner-* /opt/sonar-scanner; \
    ln -s /opt/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner; \
    rm -f /tmp/sonar-scanner.zip; \
    apt-get clean; rm -rf /var/lib/apt/lists/*

USER jenkins
ENV TZ=UTC \
    npm_config_cache=/home/jenkins/.npm \
    COREPACK_HOME=/home/jenkins/.cache/corepack \
    SONAR_SCANNER_HOME=/opt/sonar-scanner
ENTRYPOINT ["/usr/local/bin/fetch-secret-connect.sh"]

LABEL org.opencontainers.image.title="devsecops-agent-nodejs" \
      org.opencontainers.image.description="Dynamic Jenkins agent: Node 22 LTS + npm/pnpm/yarn (corepack) + sonar-scanner"
