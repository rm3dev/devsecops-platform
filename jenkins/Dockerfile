# =============================================================================
# Custom Jenkins LTS controller image (Phase 3)
#
# Build (via scripts/build-images.sh, which passes BASE_IMAGE from .env):
#   docker build --build-arg BASE_IMAGE=jenkins/jenkins:2.568.3-lts-jdk21 \
#     -t devsecops/jenkins-controller:2.568.3-lts-jdk21 jenkins/
#
# Principles:
#   * Plugins are BAKED IN at pinned versions (image immutability); JCasC and
#     init.groovy.d are MOUNTED from the repo at runtime (config as code).
#   * Runs as the unprivileged `jenkins` user (uid 1000) — never root.
#   * No Docker socket, no Docker CLI in the controller: image builds happen on
#     agents via rootless BuildKit (architecture D-04).
# =============================================================================
ARG BASE_IMAGE=jenkins/jenkins:2.568.3-lts-jdk21
FROM ${BASE_IMAGE}

USER root

# Minimal extra tooling for controller-side operations (git ships in the base
# image; curl ships in the base image). zip/unzip are needed by plugin tooling
# and report archiving helpers.
RUN apt-get update \
 && apt-get install -y --no-install-recommends zip unzip ca-certificates \
 && rm -rf /var/lib/apt/lists/*

USER jenkins

# Install the pinned plugin set (dependencies resolved automatically)
COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt \
 && rm -rf /tmp/jenkins_plugins

# JCasC location (content is bind-mounted read-only from ./jenkins/casc at
# runtime so configuration stays in Git; the env makes the contract explicit).
ENV CASC_JENKINS_CONFIG=/var/jenkins_home/casc

LABEL org.opencontainers.image.title="devsecops-jenkins-controller" \
      org.opencontainers.image.description="Jenkins LTS controller with pinned DevSecOps plugin set (JCasC-managed)" \
      org.opencontainers.image.vendor="DevSecOps Platform" \
      org.opencontainers.image.licenses="Apache-2.0"

# Base image ENTRYPOINT (/usr/local/bin/jenkins.sh) is retained.
