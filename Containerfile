# Containerfile is functionally identical to Dockerfile.
# Provided for Podman/Buildah compatibility on OpenShift.
# Build with:  podman build --build-arg QSE_TOKEN=<token> -t qse-pod:latest .
#
# Changes:
#   2026-08-21 - Initial creation (mirrors Dockerfile)
#   2026-08-21 - Made QSE CLI repo URL configurable via QSE_REPO_URL build arg

# Source the Dockerfile content - Podman/Buildah fully support Dockerfile syntax
# This file exists as the conventional name for OpenShift/Podman toolchains.

# =============================================================================
# Stage 1: builder (heavy tools + QSE clone with token)
# =============================================================================
FROM registry.access.redhat.com/ubi9/ubi AS builder

ARG QSE_TOKEN
ARG QSE_REPO_URL=https://github.ibm.com/quantum-safe-engineering/quantum-safe-read-repos.git
ARG GO_VERSION=1.22.5
ARG GRADLE_VERSION=8.8
ARG NODEJS_MAJOR=20

RUN dnf install -y --setopt=install_weak_deps=False \
        git curl wget unzip tar gzip jq findutils file \
        java-17-openjdk java-17-openjdk-devel maven \
        python3 python3-pip python3-devel \
        gcc gcc-c++ make cmake autoconf automake libtool binutils \
        dotnet-sdk-8.0 \
    && dnf clean all && rm -rf /var/cache/dnf

RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
        -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz

RUN curl -fsSL https://rpm.nodesource.com/setup_${NODEJS_MAJOR}.x | bash - \
    && dnf install -y nodejs && dnf clean all && rm -rf /var/cache/dnf \
    && npm install -g typescript

RUN curl -fsSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
        -o /tmp/gradle.zip \
    && unzip /tmp/gradle.zip -d /opt \
    && ln -s /opt/gradle-${GRADLE_VERSION}/bin/gradle /usr/local/bin/gradle \
    && rm /tmp/gradle.zip

RUN curl -fsSL "https://storage.googleapis.com/dart-archive/channels/stable/release/latest/linux_packages/dart_stable.rpm" \
        -o /tmp/dart.rpm \
    && dnf install -y /tmp/dart.rpm && rm /tmp/dart.rpm \
    && dnf clean all && rm -rf /var/cache/dnf

# Inject the token into the URL: https://<token>@<host/path>
RUN auth_url=$(echo "${QSE_REPO_URL}" | sed "s|https://|https://${QSE_TOKEN}@|") \
    && git clone --depth=1 "${auth_url}" /tmp/qse-repo \
    && mkdir -p /opt/qse \
    && cp -r /tmp/qse-repo/CLI/. /opt/qse/ \
    && chmod +x /opt/qse/*.sh \
    && rm -rf /tmp/qse-repo

# =============================================================================
# Stage 2: runtime (no token, minimal footprint)
# =============================================================================
FROM registry.access.redhat.com/ubi9/ubi AS runtime

ARG GO_VERSION=1.22.5
ARG GRADLE_VERSION=8.8
ARG NODEJS_MAJOR=20

COPY --from=builder /usr/local/go               /usr/local/go
COPY --from=builder /opt/gradle-${GRADLE_VERSION} /opt/gradle-${GRADLE_VERSION}
COPY --from=builder /opt/qse                    /opt/qse

RUN dnf install -y --setopt=install_weak_deps=False \
        git curl jq findutils file \
        java-17-openjdk maven \
        python3 python3-pip \
        gcc gcc-c++ make cmake \
        dotnet-runtime-8.0 \
    && dnf clean all && rm -rf /var/cache/dnf \
    && ln -s /opt/gradle-${GRADLE_VERSION}/bin/gradle /usr/local/bin/gradle

RUN curl -fsSL https://rpm.nodesource.com/setup_${NODEJS_MAJOR}.x | bash - \
    && dnf install -y nodejs && dnf clean all && rm -rf /var/cache/dnf \
    && npm install -g typescript

RUN curl -fsSL "https://storage.googleapis.com/dart-archive/channels/stable/release/latest/linux_packages/dart_stable.rpm" \
        -o /tmp/dart.rpm \
    && dnf install -y /tmp/dart.rpm && rm /tmp/dart.rpm \
    && dnf clean all && rm -rf /var/cache/dnf

ENV QSE_HOME=/opt/qse \
    APP_HOME=/opt/qse-pod \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk \
    GOROOT=/usr/local/go \
    GOPATH=/opt/go \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

ENV PATH="${APP_HOME}:${QSE_HOME}:${GOROOT}/bin:${GOPATH}/bin:${PATH}"

RUN mkdir -p "${APP_HOME}/results" "${APP_HOME}/workspace" "${GOPATH}" \
    && chgrp -R 0 "${APP_HOME}" "${QSE_HOME}" "${GOPATH}" \
    && chmod -R g=u "${APP_HOME}" "${QSE_HOME}" "${GOPATH}"

COPY scripts/scan.sh "${APP_HOME}/scan.sh"
RUN chmod +x "${APP_HOME}/scan.sh" \
    && chgrp 0 "${APP_HOME}/scan.sh" && chmod g=u "${APP_HOME}/scan.sh"

USER 1001
WORKDIR ${APP_HOME}

ENTRYPOINT ["/bin/bash", "/opt/qse-pod/scan.sh"]
