# =============================================================================
# agent-security — all pipeline security stages (Phase 7)
# Tooling: trivy, gitleaks, semgrep (+ baked offline rulesets), syft, cosign,
#          kubescape, OWASP Dependency-Check CLI.
# Versions pinned & URL-verified 2026-10-30; Dependency-Check 12.1.0 re-verified
# 2026-10-31 (GitHub release + owasp/dependency-check:12.1.0 image — the SAME
# version must be used by security/scripts/20-dependency-check-db.sh so the
# H2/NVD data schema matches the CLI).
#
# Offline-first (D-16 — agents have no internet):
#   * semgrep rulesets baked from semgrep.dev at IMAGE BUILD time → /opt/semgrep-rules
#   * trivy vulnerability DBs pulled at RUNTIME through Nexus (ghcr-proxy member
#     of docker-group): TRIVY_DB_REPOSITORY=registry.<domain>/aquasecurity/trivy-db
#   * Dependency-Check NVD mirror lives in a host-maintained volume mounted at
#     /owasp-dc (updated by security/scripts/20-dependency-check-db.sh); scans
#     run with --noupdate.
#   * platform CA baked for registry.<domain> TLS (image pulls, cosign, syft).
# Cache: TRIVY_CACHE_DIR under /home/jenkins/.cache — trivy-cache compose volume.
# =============================================================================
ARG INBOUND_AGENT_IMAGE=jenkins/inbound-agent:3395.v6e5377b_0fb_3c-3-jdk21
FROM ${INBOUND_AGENT_IMAGE}

ARG TRIVY_VERSION=0.76.1
ARG GITLEAKS_VERSION=8.30.1
ARG SEMGREP_VERSION=1.183.0
ARG SYFT_VERSION=1.55.0
ARG COSIGN_VERSION=3.1.4
ARG KUBESCAPE_VERSION=4.0.17
ARG DEPENDENCY_CHECK_VERSION=12.1.0

USER root
COPY common/fetch-secret-connect.sh /usr/local/bin/fetch-secret-connect.sh
# Platform internal CA (staged into the context by scripts/build-images.sh) —
# required for registry.<domain> TLS: trivy/syft/cosign image operations.
COPY common/platform-ca.crt /usr/local/share/ca-certificates/platform-ca.crt

RUN set -eux; \
    update-ca-certificates; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates git unzip tar gzip \
        python3 python3-venv python3-pip; \
    # --- trivy (fs / image / SBOM scanning) ---
    curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
      | tar -xz -C /usr/local/bin trivy; \
    # --- gitleaks (secret scanning) ---
    curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
      | tar -xz -C /usr/local/bin gitleaks; \
    # --- syft (SBOM: CycloneDX + SPDX) ---
    curl -fsSL "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_linux_amd64.tar.gz" \
      | tar -xz -C /usr/local/bin syft; \
    # --- cosign (image signing/verification; keys → Vault in Phase 11) ---
    curl -fsSL -o /usr/local/bin/cosign \
      "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64"; \
    # --- kubescape (cluster posture; scans run in Phase 8) ---
    curl -fsSL "https://github.com/kubescape/kubescape/releases/download/v${KUBESCAPE_VERSION}/kubescape_${KUBESCAPE_VERSION}_linux_amd64.tar.gz" \
      | tar -xz -C /usr/local/bin kubescape; \
    chmod 0755 /usr/local/bin/{trivy,gitleaks,syft,cosign,kubescape}; \
    # --- OWASP Dependency-Check CLI (NVD data comes from the /owasp-dc volume) ---
    curl -fsSL -o /tmp/dc.zip \
      "https://github.com/jeremylong/DependencyCheck/releases/download/v${DEPENDENCY_CHECK_VERSION}/dependency-check-${DEPENDENCY_CHECK_VERSION}-release.zip"; \
    unzip -q /tmp/dc.zip -d /opt; rm -f /tmp/dc.zip; \
    ln -s /opt/dependency-check/bin/dependency-check.sh /usr/local/bin/dependency-check.sh; \
    # --- semgrep (SAST) in an isolated venv (PEP 668-safe) ---
    python3 -m venv /opt/venv-semgrep; \
    /opt/venv-semgrep/bin/pip install --no-cache-dir "semgrep==${SEMGREP_VERSION}"; \
    ln -s /opt/venv-semgrep/bin/semgrep /usr/local/bin/semgrep; \
    # --- semgrep rulesets baked for OFFLINE scans (p/default, OWASP top ten,
    #     security-audit incl. Dockerfile rules); refreshed on image rebuild ---
    mkdir -p /opt/semgrep-rules; \
    curl -fsSL -o /opt/semgrep-rules/default.yml        "https://semgrep.dev/c/p/default"; \
    curl -fsSL -o /opt/semgrep-rules/owasp-top-ten.yml  "https://semgrep.dev/c/p/owasp-top-ten"; \
    curl -fsSL -o /opt/semgrep-rules/security-audit.yml "https://semgrep.dev/c/p/security-audit"; \
    apt-get clean; rm -rf /var/lib/apt/lists/*

USER jenkins
ENV TZ=UTC \
    TRIVY_CACHE_DIR=/home/jenkins/.cache/trivy \
    SEMGREP_SETTINGS_FILE=/home/jenkins/.cache/semgrep/settings.yml \
    SEMGREP_ENABLE_METRICS=off
ENTRYPOINT ["/usr/local/bin/fetch-secret-connect.sh"]

LABEL org.opencontainers.image.title="devsecops-agent-security" \
      org.opencontainers.image.description="Warm Jenkins agent: trivy, gitleaks, semgrep(+rules), syft, cosign, kubescape, dependency-check CLI"
