# =============================================================================
# agent-dotnet — .NET builds (restore/build/test/publish, Coverlet coverage)
# SDK 9.0.320 installed via the official dotnet-install script (pinned
# --version, never a channel float). dotnet-sonarscanner 12.0.0 as a
# tool-path install so it is shared by the runtime `jenkins` user.
# =============================================================================
ARG INBOUND_AGENT_IMAGE=jenkins/inbound-agent:3395.v6e5377b_0fb_3c-3-jdk21
FROM ${INBOUND_AGENT_IMAGE}

ARG DOTNET_SDK_VERSION=9.0.320
ARG DOTNET_SONARSCANNER_VERSION=12.0.0

USER root
COPY common/fetch-secret-connect.sh /usr/local/bin/fetch-secret-connect.sh

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates git unzip zip; \
    curl -fsSL -o /tmp/dotnet-install.sh https://dot.net/v1/dotnet-install.sh; \
    bash /tmp/dotnet-install.sh --version "${DOTNET_SDK_VERSION}" --install-dir /usr/share/dotnet; \
    ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet; \
    rm -f /tmp/dotnet-install.sh; \
    export DOTNET_ROOT=/usr/share/dotnet DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
           DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1; \
    dotnet tool install --tool-path /usr/local/bin dotnet-sonarscanner \
        --version "${DOTNET_SONARSCANNER_VERSION}"; \
    dotnet nuget locals all --clear >/dev/null || true; \
    apt-get clean; rm -rf /var/lib/apt/lists/*

USER jenkins
ENV TZ=UTC \
    DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 \
    NUGET_PACKAGES=/home/jenkins/.nuget/packages
ENTRYPOINT ["/usr/local/bin/fetch-secret-connect.sh"]

LABEL org.opencontainers.image.title="devsecops-agent-dotnet" \
      org.opencontainers.image.description="Dynamic Jenkins agent: .NET SDK 9.0.320 + dotnet-sonarscanner"
