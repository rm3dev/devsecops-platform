# =============================================================================
# agent-general — GitOps, container build/push, deployment verification,
#                 post-deploy smoke tests (Phase 9)
# Tooling: git, kubectl (read-only verify + port-forward tunnel), helm
#          (lint/template), kustomize, buildctl (→ rootless BuildKit daemon),
#          crane (registry ops), yq, jq, argocd CLI (sync trigger/status),
#          k6 + node/newman (postDeploy smoke tests — D-31).
# All versions verified 2026-10-31 (HTTP 200 on every download URL).
# =============================================================================
ARG INBOUND_AGENT_IMAGE=jenkins/inbound-agent:3395.v6e5377b_0fb_3c-3-jdk21
FROM ${INBOUND_AGENT_IMAGE}

ARG KUBECTL_VERSION=v1.35.10
ARG HELM_VERSION=v3.22.1
ARG KUSTOMIZE_VERSION=v5.8.3
ARG BUILDKIT_VERSION=v0.34.1
ARG CRANE_VERSION=v0.22.1
ARG YQ_VERSION=v4.54.1
ARG ARGOCD_VERSION=v3.4.8
ARG SONAR_SCANNER_VERSION=8.3.0.16463
# Phase 9 smoke-test tooling (versions verified 2026-10-31)
ARG K6_VERSION=v2.3.0
ARG NODE_VERSION=v22.23.4
ARG NEWMAN_VERSION=6.2.3

USER root
COPY common/fetch-secret-connect.sh /usr/local/bin/fetch-secret-connect.sh
# Platform internal CA — copied into the build context by scripts/build-images.sh
# from reverse-proxy/certificates/ca.crt. Required so buildctl/crane trust the
# TLS endpoint registry.<domain> (Traefik-terminated, internal CA) — Phase 6/D-23.
COPY common/platform-ca.crt /usr/local/share/ca-certificates/platform-ca.crt

RUN set -eux; \
    update-ca-certificates; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates git openssh-client \
        unzip zip jq tar gzip xz-utils; \
    # kubectl (deployment verification — read-only RBAC enforced cluster-side)
    curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"; \
    chmod 0755 /usr/local/bin/kubectl; \
    # helm v3 (chart lint/template locally; ArgoCD renders for real)
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz -C /tmp; \
    install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm; rm -rf /tmp/linux-amd64; \
    # kustomize
    curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION#kustomize/}_linux_amd64.tar.gz" | tar -xz -C /usr/local/bin; \
    chmod 0755 /usr/local/bin/kustomize; \
    # buildctl (talks to buildkitd over the internal agents network)
    curl -fsSL "https://github.com/moby/buildkit/releases/download/${BUILDKIT_VERSION}/buildkit-${BUILDKIT_VERSION}.linux-amd64.tar.gz" | tar -xz -C /tmp; \
    install -m 0755 /tmp/bin/buildctl /usr/local/bin/buildctl; rm -rf /tmp/bin; \
    # crane (push/copy/tag/digest operations against Nexus registry)
    curl -fsSL "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz" | tar -xz -C /usr/local/bin crane; \
    chmod 0755 /usr/local/bin/crane; \
    # yq (GitOps YAML updates)
    curl -fsSL -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"; \
    chmod 0755 /usr/local/bin/yq; \
    # argocd CLI (pinned to server version — architecture §3.4)
    curl -fsSL -o /usr/local/bin/argocd "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64"; \
    chmod 0755 /usr/local/bin/argocd; \
    # sonar-scanner CLI (Phase 5: fallback quality-gate analysis on 'general')
    curl -fsSL -o /tmp/sonar-scanner.zip \
      "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip"; \
    unzip -q /tmp/sonar-scanner.zip -d /opt; \
    mv /opt/sonar-scanner-* /opt/sonar-scanner; \
    ln -s /opt/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner; \
    rm -f /tmp/sonar-scanner.zip; \
    # k6 (Phase 9 postDeploy load/smoke scripts — tests/k6/*.js in service repos)
    curl -fsSL "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-amd64.tar.gz" | tar -xz -C /tmp; \
    install -m 0755 "/tmp/k6-${K6_VERSION}-linux-amd64/k6" /usr/local/bin/k6; \
    rm -rf "/tmp/k6-${K6_VERSION}-linux-amd64"; \
    # node runtime + newman (Phase 9 API smoke tests — tests/postman/*.json);
    # node pin matches agent-node (Phase 3) so collections run on the same major
    curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-x64.tar.xz" | tar -xJ -C /opt; \
    mv "/opt/node-${NODE_VERSION}-linux-x64" /opt/node; \
    ln -s /opt/node/bin/node /usr/local/bin/node; \
    ln -s /opt/node/bin/npm  /usr/local/bin/npm; \
    ln -s /opt/node/bin/npx  /usr/local/bin/npx; \
    npm install -g --no-fund --no-audit "newman@${NEWMAN_VERSION}"; \
    ln -s /opt/node/bin/newman /usr/local/bin/newman; \
    npm cache clean --force; \
    apt-get clean; rm -rf /var/lib/apt/lists/*

USER jenkins
ENV TZ=UTC \
    SONAR_SCANNER_HOME=/opt/sonar-scanner
ENTRYPOINT ["/usr/local/bin/fetch-secret-connect.sh"]

LABEL org.opencontainers.image.title="devsecops-agent-general" \
      org.opencontainers.image.description="Warm Jenkins agent: GitOps, BuildKit client, registry ops, deployment verification"
