# =============================================================================
# agent-python — Python microservice builds
# Runtime: CPython 3.12 (multi-stage copy from the official image; projects
# needing other versions use `uv`/pyenv per-repo, documented in pipeline.md).
# Tooling: pip, venv, poetry (pinned), build, sonar-scanner CLI.
# =============================================================================
ARG INBOUND_AGENT_IMAGE=jenkins/inbound-agent:3395.v6e5377b_0fb_3c-3-jdk21
ARG PYTHON_IMAGE=python:3.12.16-slim-bookworm
FROM ${PYTHON_IMAGE} AS python-runtime

FROM ${INBOUND_AGENT_IMAGE}

ARG POETRY_VERSION=2.5.1
ARG SONAR_SCANNER_VERSION=8.3.0.16463

USER root
COPY common/fetch-secret-connect.sh /usr/local/bin/fetch-secret-connect.sh
# CPython 3.12 toolchain (merged into /usr/local; keeps the inbound-agent
# launcher scripts intact — different filenames)
COPY --from=python-runtime /usr/local /usr/local

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates git unzip zip \
        build-essential libffi-dev libssl-dev; \
    ldconfig; \
    # Isolated tool venv (PEP 668-safe): poetry + build
    python3.12 -m venv /opt/venv-tools; \
    /opt/venv-tools/bin/pip install --no-cache-dir "poetry==${POETRY_VERSION}" build; \
    ln -s /opt/venv-tools/bin/poetry /usr/local/bin/poetry; \
    # SonarScanner CLI (shared zip distribution, version pinned)
    curl -fsSL -o /tmp/sonar-scanner.zip \
      "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip"; \
    unzip -q /tmp/sonar-scanner.zip -d /opt; \
    mv /opt/sonar-scanner-* /opt/sonar-scanner; \
    ln -s /opt/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner; \
    rm -f /tmp/sonar-scanner.zip; \
    apt-get clean; rm -rf /var/lib/apt/lists/*

USER jenkins
ENV TZ=UTC \
    PYTHONUNBUFFERED=1 \
    PIP_CACHE_DIR=/home/jenkins/.cache/pip \
    POETRY_VIRTUALENVS_IN_PROJECT=true \
    SONAR_SCANNER_HOME=/opt/sonar-scanner
ENTRYPOINT ["/usr/local/bin/fetch-secret-connect.sh"]

LABEL org.opencontainers.image.title="devsecops-agent-python" \
      org.opencontainers.image.description="Warm Jenkins agent: Python 3.12, poetry, pytest, sonar-scanner"
