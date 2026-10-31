# =============================================================================
# agent-java-maven — Java/Spring Boot builds (Maven)
# JDK 21 comes from the inbound-agent base (-jdk21). Maven 3.9.16 pinned.
# Projects SHOULD prefer ./mvnw (wrapper) — the image Maven is the fallback
# and the version used when no wrapper exists.
# Sonar analysis for Java goes through the sonar-maven plugin inside the
# project build; the standalone sonar-scanner is included for flexibility.
# =============================================================================
ARG INBOUND_AGENT_IMAGE=jenkins/inbound-agent:3395.v6e5377b_0fb_3c-3-jdk21
FROM ${INBOUND_AGENT_IMAGE}

ARG MAVEN_VERSION=3.9.16
ARG SONAR_SCANNER_VERSION=8.3.0.16463

USER root
COPY common/fetch-secret-connect.sh /usr/local/bin/fetch-secret-connect.sh

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates git unzip zip; \
    curl -fsSL "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
      | tar -xz -C /opt; \
    mv /opt/apache-maven-${MAVEN_VERSION} /opt/maven; \
    ln -s /opt/maven/bin/mvn /usr/local/bin/mvn; \
    curl -fsSL -o /tmp/sonar-scanner.zip \
      "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip"; \
    unzip -q /tmp/sonar-scanner.zip -d /opt; \
    mv /opt/sonar-scanner-* /opt/sonar-scanner; \
    ln -s /opt/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner; \
    rm -f /tmp/sonar-scanner.zip; \
    apt-get clean; rm -rf /var/lib/apt/lists/*

USER jenkins
ENV TZ=UTC \
    MAVEN_HOME=/opt/maven \
    MAVEN_OPTS="-Dmaven.repo.local=/home/jenkins/.m2/repository" \
    SONAR_SCANNER_HOME=/opt/sonar-scanner
ENTRYPOINT ["/usr/local/bin/fetch-secret-connect.sh"]

LABEL org.opencontainers.image.title="devsecops-agent-java-maven" \
      org.opencontainers.image.description="Dynamic Jenkins agent: JDK 21 + Maven 3.9.16 + sonar-scanner"
