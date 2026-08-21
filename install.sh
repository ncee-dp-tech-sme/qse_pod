#!/usr/bin/env bash
# =============================================================================
# install.sh - Deploy QSE Pod to OpenShift or Kubernetes
#
# Applies all manifests in the correct order, verifies prerequisites,
# and confirms with the user before making any cluster changes.
#
# Usage:
#   ./install.sh [--namespace <ns>] [--kubeconfig <path>] [--openshift] [--dry-run]
#
# Options:
#   --namespace  <ns>    Namespace to deploy into (default: qse-pod)
#   --kubeconfig <path>  Path to kubeconfig file (default: ~/.kube/config)
#   --openshift          Also apply the OpenShift SCC manifest
#   --dry-run            Print what would be applied without making changes
#   --always-allow       Skip the confirmation prompt
#
# Prerequisites:
#   - kubectl (or oc) on PATH and authenticated to a cluster
#   - k8s/secret.yaml populated with real credentials (not placeholder values)
#
# Changes:
#   2026-08-21 04:01:56 - Initial creation: namespace, manifests, SCC support
#   2026-08-21 04:10:14 - Added repos-configmap.yaml to apply sequence
# =============================================================================

set -euo pipefail

# ---- Defaults ----------------------------------------------------------------
NAMESPACE="qse-pod"
KUBECONFIG_ARG=""
APPLY_SCC=false
DRY_RUN=false
ALWAYS_ALLOW=false
MANIFESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/k8s" && pwd)"

# ---- Logging -----------------------------------------------------------------
log()   { echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] [$1] ${*:2}"; }
info()  { log "INFO " "$@"; }
warn()  { log "WARN " "$@"; }
error() { log "ERROR" "$@"; }

# ---- Parse arguments ---------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)    NAMESPACE="$2";       shift 2 ;;
        --kubeconfig)   KUBECONFIG_ARG="--kubeconfig $2"; shift 2 ;;
        --openshift)    APPLY_SCC=true;        shift ;;
        --dry-run)      DRY_RUN=true;          shift ;;
        --always-allow) ALWAYS_ALLOW=true;     shift ;;
        -h|--help)
            sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)  error "Unknown argument: $1"; exit 1 ;;
    esac
done

# ---- kubectl or oc wrapper ---------------------------------------------------
# Use oc if available and --openshift flag set; fall back to kubectl
KUBECTL="kubectl"
if [[ "${APPLY_SCC}" == "true" ]] && command -v oc &>/dev/null; then
    KUBECTL="oc"
    info "OpenShift mode: using 'oc' CLI."
fi

# Apply kubeconfig override if given
# shellcheck disable=SC2086
kube() { ${KUBECTL} ${KUBECONFIG_ARG} "$@"; }

# ---- Preflight checks --------------------------------------------------------
preflight() {
    info "Running preflight checks..."

    if ! command -v "${KUBECTL}" &>/dev/null; then
        error "'${KUBECTL}' not found on PATH. Install kubectl or oc first."
        exit 1
    fi

    if ! kube cluster-info &>/dev/null; then
        error "Cannot reach the cluster. Check your kubeconfig / login."
        exit 1
    fi

    # Warn if secret.yaml still has placeholder values
    if grep -q "REPLACE_WITH" "${MANIFESTS_DIR}/secret.yaml" 2>/dev/null; then
        error "k8s/secret.yaml still contains placeholder values."
        error "Edit it and replace all REPLACE_WITH_* entries before deploying."
        exit 1
    fi

    info "Preflight checks passed."
}

# ---- Summary and confirmation ------------------------------------------------
confirm() {
    local dry_label=""
    [[ "${DRY_RUN}" == "true" ]] && dry_label=" [DRY RUN — no changes will be made]"

    echo ""
    echo "============================================================"
    echo "  QSE Pod Installer${dry_label}"
    echo "============================================================"
    echo "  Cluster       : $(kube config current-context 2>/dev/null || echo '<unknown>')"
    echo "  Namespace     : ${NAMESPACE}"
    echo "  Manifests dir : ${MANIFESTS_DIR}"
    echo "  OpenShift SCC : ${APPLY_SCC}"
    echo ""
    echo "  ACTIONS THAT WILL BE TAKEN:"
    echo "    1. Create namespace '${NAMESPACE}' (if it doesn't exist)"
    echo "    2. Apply ServiceAccount, Role, and RoleBinding"
    echo "    3. Apply Secret (credentials)"
    echo "    4. Apply ConfigMap (configuration)"
    echo "    5. Apply PersistentVolumeClaim (results storage)"
    echo "    6. Apply CronJob (scheduled scan)"
    if [[ "${APPLY_SCC}" == "true" ]]; then
        echo "    7. Apply OpenShift SecurityContextConstraints (cluster-admin required)"
    fi
    echo ""
    echo "  ⚠  This will create/update resources in the cluster."
    echo "============================================================"
    echo ""

    if [[ "${ALWAYS_ALLOW}" == "true" || "${DRY_RUN}" == "true" ]]; then
        return 0
    fi

    if [[ ! -t 0 ]]; then
        info "Non-interactive session — proceeding automatically."
        return 0
    fi

    read -r -p "Proceed? [y/N] " answer
    case "${answer}" in
        [Yy]) return 0 ;;
        *)    info "Aborted by user."; exit 0 ;;
    esac
}

# ---- Apply a manifest --------------------------------------------------------
apply() {
    local label="$1" file="$2"
    if [[ ! -f "${file}" ]]; then
        warn "Manifest not found, skipping: ${file}"
        return
    fi
    info "Applying ${label}: ${file}"
    if [[ "${DRY_RUN}" == "true" ]]; then
        kube apply -f "${file}" -n "${NAMESPACE}" --dry-run=client
    else
        kube apply -f "${file}" -n "${NAMESPACE}"
    fi
}

# ---- Apply SCC (cluster-scoped, no namespace flag) ---------------------------
apply_scc() {
    local file="${MANIFESTS_DIR}/scc.yaml"
    if [[ ! -f "${file}" ]]; then
        warn "SCC manifest not found: ${file}"
        return
    fi
    info "Applying OpenShift SCC: ${file}"
    if [[ "${DRY_RUN}" == "true" ]]; then
        kube apply -f "${file}" --dry-run=client
    else
        kube apply -f "${file}"
    fi
}

# ---- Create namespace if it doesn't exist ------------------------------------
ensure_namespace() {
    if kube get namespace "${NAMESPACE}" &>/dev/null; then
        info "Namespace '${NAMESPACE}' already exists."
    else
        info "Creating namespace: ${NAMESPACE}"
        if [[ "${DRY_RUN}" == "true" ]]; then
            info "[dry-run] Would create namespace ${NAMESPACE}"
        else
            kube create namespace "${NAMESPACE}"
        fi
    fi
}

# ---- Verify deployment -------------------------------------------------------
verify() {
    [[ "${DRY_RUN}" == "true" ]] && return

    info "Verifying deployed resources in namespace '${NAMESPACE}'..."
    echo ""
    kube get serviceaccount,secret,configmap,pvc,cronjob \
        -n "${NAMESPACE}" -l app=qse-pod 2>/dev/null \
        || warn "Could not list resources — check permissions."

    echo ""
    info "Deployment complete."
    info "Monitor the CronJob with:"
    info "  ${KUBECTL} get cronjob qse-pod-scan -n ${NAMESPACE} -w"
    info "  ${KUBECTL} get jobs -n ${NAMESPACE} -l app=qse-pod"
    info "  ${KUBECTL} logs -n ${NAMESPACE} -l app=qse-pod --tail=50"
}

# ---- Main --------------------------------------------------------------------
main() {
    preflight
    confirm

    ensure_namespace

    # Apply in dependency order
    apply "ServiceAccount/Role/RoleBinding" "${MANIFESTS_DIR}/serviceaccount.yaml"
    apply "Secret"                          "${MANIFESTS_DIR}/secret.yaml"
    apply "ConfigMap (global config)"       "${MANIFESTS_DIR}/configmap.yaml"
    apply "ConfigMap (repos list)"          "${MANIFESTS_DIR}/repos-configmap.yaml"
    apply "PersistentVolumeClaim"           "${MANIFESTS_DIR}/pvc.yaml"
    apply "CronJob"                         "${MANIFESTS_DIR}/cronjob.yaml"

    if [[ "${APPLY_SCC}" == "true" ]]; then
        apply_scc
    fi

    verify
}

main "$@"
