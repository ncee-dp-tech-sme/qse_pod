# =============================================================================
# QSE Pod - Quantum Safe Explorer scan container
# Supports: Java, Go, Python, C++, C#, Dart, JavaScript/TypeScript
# Compatible with OpenShift (arbitrary UID / restricted SCC) and Kubernetes.
#
# Changes:
#   2026-08-21 - Initial creation
#   2026-08-21 - Made QSE CLI repo URL configurable via QSE_REPO_URL build arg
# =============================================================================

FROM registry.access.redhat.com/ubi9/ubi AS builder

# ---- Build-time arguments ----------------------------------------------------
# QSE_TOKEN is used ONLY during build to clone the QSE CLI repo.
# QSE_REPO_URL is the base HTTPS URL of the repo (without credentials).
# Both are stripped from the final runtime layer via multi-stage build.
ARG QSE_TOKEN
ARG QSE_REPO_URL=https://github.ibm.com/quantum-safe-engineering/quantum-safe-read-repos.git
ARG GO_VERSION=1.22.5
ARG GRADLE_VERSION=8.8
ARG NODEJS_MAJOR=20

# ---- OS-level packages -------------------------------------------------------
RUN dnf install -y --setopt=install_weak_deps=False \
        git curl wget unzip tar gzip jq findutils file \
        java-17-openjdk java-17-openjdk-devel maven \
        python3 python3-pip python3-devel \
        gcc gcc-c++ make cmake autoconf automake libtool binutils \
        dotnet-sdk-8.0 \
    && dnf clean all && rm -rf /var/cache/dnf

# ---- Go ----------------------------------------------------------------------
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
        -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz

# ---- Node.js (for JS/TS scanning) -------------------------------------------
RUN curl -fsSL https://rpm.nodesource.com/setup_${NODEJS_MAJOR}.x | bash - \
    && dnf install -y nodejs && dnf clean all && rm -rf /var/cache/dnf \
    && npm install -g typescript

# ---- Gradle (alternative Java build tool) ------------------------------------
RUN curl -fsSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
        -o /tmp/gradle.zip \
    && unzip /tmp/gradle.zip -d /opt \
    && ln -s /opt/gradle-${GRADLE_VERSION}/bin/gradle /usr/local/bin/gradle \
    && rm /tmp/gradle.zip

# ---- Dart SDK ----------------------------------------------------------------
RUN curl -fsSL https://dl-ssl.google.com/linux/linux_signing_key.pub \
        -o /etc/pki/rpm-gpg/RPM-GPG-KEY-dart \
    && curl -fsSL "https://storage.googleapis.com/dart-archive/channels/stable/release/latest/linux_packages/dart_stable.rpm" \
        -o /tmp/dart.rpm \
    && dnf install -y /tmp/dart.rpm && rm /tmp/dart.rpm \
    && dnf clean all && rm -rf /var/cache/dnf

# ---- Clone QSE CLI (token used here, not copied to runtime layer) ------------
# Inject the token into the URL: https://<token>@<host/path>
RUN auth_url=$(echo "${QSE_REPO_URL}" | sed "s|https://|https://${QSE_TOKEN}@|") \
    && git clone --depth=1 "${auth_url}" /tmp/qse-repo \
    && mkdir -p /opt/qse \
    && cp -r /tmp/qse-repo/CLI/. /opt/qse/ \
    && chmod +x /opt/qse/*.sh \
    && rm -rf /tmp/qse-repo

# =============================================================================
# Runtime image - token is NOT present here
# =============================================================================
FROM registry.access.redhat.com/ubi9/ubi AS runtime

ARG GO_VERSION=1.22.5
ARG GRADLE_VERSION=8.8
ARG NODEJS_MAJOR=20

# ---- Copy build artefacts from builder layer ---------------------------------
COPY --from=builder /usr/local/go        /usr/local/go
COPY --from=builder /opt/gradle-${GRADLE_VERSION} /opt/gradle-${GRADLE_VERSION}
COPY --from=builder /opt/qse             /opt/qse

# ---- Runtime OS packages (no build headers needed) ---------------------------
RUN dnf install -y --setopt=install_weak_deps=False \
        git curl jq findutils file \
        java-17-openjdk maven \
        python3 python3-pip \
        gcc gcc-c++ make cmake \
        dotnet-runtime-8.0 \
    && dnf clean all && rm -rf /var/cache/dnf \
    && ln -s /opt/gradle-${GRADLE_VERSION}/bin/gradle /usr/local/bin/gradle

# ---- Node.js (runtime only) --------------------------------------------------
RUN curl -fsSL https://rpm.nodesource.com/setup_${NODEJS_MAJOR}.x | bash - \
    && dnf install -y nodejs && dnf clean all && rm -rf /var/cache/dnf \
    && npm install -g typescript

# ---- Dart runtime ------------------------------------------------------------
RUN curl -fsSL "https://storage.googleapis.com/dart-archive/channels/stable/release/latest/linux_packages/dart_stable.rpm" \
        -o /tmp/dart.rpm \
    && dnf install -y /tmp/dart.rpm && rm /tmp/dart.rpm \
    && dnf clean all && rm -rf /var/cache/dnf

# ---- App directories ---------------------------------------------------------
ENV QSE_HOME=/opt/qse \
    APP_HOME=/opt/qse-pod \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk \
    GOROOT=/usr/local/go \
    GOPATH=/opt/go \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

ENV PATH="${APP_HOME}:${QSE_HOME}:${GOROOT}/bin:${GOPATH}/bin:${PATH}"

RUN mkdir -p "${APP_HOME}/results" "${APP_HOME}/workspace" "${GOPATH}" \
    # OpenShift: directories must be group-writable (GID 0)
    && chgrp -R 0 "${APP_HOME}" "${QSE_HOME}" "${GOPATH}" \
    && chmod -R g=u "${APP_HOME}" "${QSE_HOME}" "${GOPATH}"

COPY scripts/scan.sh "${APP_HOME}/scan.sh"
RUN chmod +x "${APP_HOME}/scan.sh" \
    && chgrp 0 "${APP_HOME}/scan.sh" && chmod g=u "${APP_HOME}/scan.sh"

# Run as non-root (OpenShift overrides UID but keeps GID=0)
USER 1001
WORKDIR ${APP_HOME}

ENTRYPOINT ["/bin/bash", "/opt/qse-pod/scan.sh"]
