# =============================================================================
# agent-java-gradle — Java/Spring Boot builds (Gradle)
# JDK 21 from base; Gradle 8.14.6 pinned. Projects SHOULD prefer ./gradlew
# (wrapper); the image Gradle is the fallback.
# =============================================================================
ARG INBOUND_AGENT_IMAGE=jenkins/inbound-agent:3395.v6e5377b_0fb_3c-3-jdk21
FROM ${INBOUND_AGENT_IMAGE}

ARG GRADLE_VERSION=8.14.6
ARG SONAR_SCANNER_VERSION=8.3.0.16463

USER root
COPY common/fetch-secret-connect.sh /usr/local/bin/fetch-secret-connect.sh

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates git unzip zip; \
    curl -fsSL -o /tmp/gradle.zip "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip"; \
    unzip -q /tmp/gradle.zip -d /opt; \
    mv /opt/gradle-${GRADLE_VERSION} /opt/gradle; \
    ln -s /opt/gradle/bin/gradle /usr/local/bin/gradle; \
    rm -f /tmp/gradle.zip; \
    curl -fsSL -o /tmp/sonar-scanner.zip \
      "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip"; \
    unzip -q /tmp/sonar-scanner.zip -d /opt; \
    mv /opt/sonar-scanner-* /opt/sonar-scanner; \
    ln -s /opt/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner; \
    rm -f /tmp/sonar-scanner.zip; \
    apt-get clean; rm -rf /var/lib/apt/lists/*

USER jenkins
ENV TZ=UTC \
    GRADLE_HOME=/opt/gradle \
    GRADLE_USER_HOME=/home/jenkins/.gradle \
    SONAR_SCANNER_HOME=/opt/sonar-scanner
ENTRYPOINT ["/usr/local/bin/fetch-secret-connect.sh"]

LABEL org.opencontainers.image.title="devsecops-agent-java-gradle" \
      org.opencontainers.image.description="Dynamic Jenkins agent: JDK 21 + Gradle 8.14.6 + sonar-scanner"
