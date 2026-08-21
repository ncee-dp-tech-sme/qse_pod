#!/usr/bin/env bash
# =============================================================================
# scan.sh - QSE Pod scan orchestration script
#
# Reads a list of Git repositories from a mounted ConfigMap file and runs a
# Quantum Safe Explorer (QSE) cryptographic scan on each one in sequence.
# Results are uploaded to Guardium Cryptography Manager (GCM) per repo.
#
# All sensitive values are loaded from a .env file or injected as Kubernetes
# Secret environment variables. No credentials are ever hardcoded.
#
# Environment variables (loaded from .env or injected by K8s Secret/ConfigMap):
#   REPOS_FILE          - Path to the mounted repos YAML file
#                         Default: /etc/qse-repos/repos.yaml
#   GIT_USERNAME        - Git username for private repos (optional)
#   GIT_TOKEN           - Git personal access token (optional)
#   GCM_SERVER_URL      - GCM base URL, e.g. https://gcm.example.com
#   GCM_API_KEY         - GCM API key for authentication
#   APP_VERSION         - Version label override (default: commit short SHA)
#   EXCLUDE_PATHS       - Default comma-separated paths to exclude (per-repo can override)
#   QSE_OUTPUT_BASE_DIR - Base dir for scan outputs; sub-dirs created per repo
#                         Default: /opt/qse-pod/results/scans
#   LAST_COMMIT_BASE_DIR- Base dir for per-repo last-commit SHA files
#                         Default: /opt/qse-pod/results/commits
#   SCAN_ALL_LANGUAGES  - "true" to force scan all supported languages
#   CONFIGMAP_NAME      - ConfigMap name for commit SHA persistence (optional)
#   CONFIGMAP_NAMESPACE - Namespace of above ConfigMap (optional)
#   ALWAYS_ALLOW        - "true" to skip the confirmation prompt
#
# Repos file format (repos.yaml mounted from qse-pod-repos ConfigMap):
#   repos:
#     - url: https://github.com/org/repo.git
#       app_name: my-app          # optional; defaults to repo name
#       exclude_paths: src/test   # optional; overrides global EXCLUDE_PATHS
#
# Changes:
#   2026-08-21 04:01:56 - Initial creation: multi-language scan + GCM upload
#   2026-08-21 04:01:56 - Added .env loading, confirmation prompt, coding-standards compliance
#   2026-08-21 04:10:14 - Multi-repo support: read repo list from mounted ConfigMap file
# =============================================================================

set -euo pipefail

# ---- Load .env if present (not required in-cluster; overridden by K8s env) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    set -o allexport
    source "${ENV_FILE}"
    set +o allexport
fi

# ---- Constants ---------------------------------------------------------------
readonly TIMESTAMP_FORMAT='%Y-%m-%dT%H:%M:%S%z'
readonly REPOS_FILE="${REPOS_FILE:-/etc/qse-repos/repos.yaml}"
readonly QSE_OUTPUT_BASE_DIR="${QSE_OUTPUT_BASE_DIR:-/opt/qse-pod/results/scans}"
readonly LAST_COMMIT_BASE_DIR="${LAST_COMMIT_BASE_DIR:-/opt/qse-pod/results/commits}"
readonly QSE_CLI="${QSE_HOME:-/opt/qse}/cli.sh"
readonly MAX_RETRIES=3
readonly RETRY_BASE_DELAY=5

# Temp workspace root — individual repo workspaces are sub-dirs
readonly WORKSPACE_ROOT="/opt/qse-pod/workspace"

# ---- Logging: timestamp-prefixed output to stderr -- 2026-08-21 04:01:56 ----
log()   { echo "[$(date +"${TIMESTAMP_FORMAT}")] [$1] ${*:2}" >&2; }
info()  { log "INFO " "$@"; }
warn()  { log "WARN " "$@"; }
error() { log "ERROR" "$@"; }

# ---- Global cleanup: wipe entire workspace root on exit -- 2026-08-21 04:10:14
CLEANUP_DONE=false
cleanup() {
    if [[ "${CLEANUP_DONE}" == "false" ]]; then
        CLEANUP_DONE=true
        if [[ -d "${WORKSPACE_ROOT}" ]]; then
            info "Cleaning up workspace root: ${WORKSPACE_ROOT}"
            rm -rf "${WORKSPACE_ROOT}"
        fi
    fi
}
trap cleanup EXIT INT TERM

# ---- Show summary and ask for confirmation -- 2026-08-21 04:01:56 ------------
# Reads ALWAYS_ALLOW from .env or environment to skip interactive prompt.
confirm_execution() {
    local repo_count="$1"
    echo ""
    echo "============================================================"
    echo "  QSE Pod - Quantum Safe Explorer Multi-Repo Scan"
    echo "============================================================"
    echo "  Repos file    : ${REPOS_FILE}"
    echo "  Repositories  : ${repo_count} configured"
    echo "  GCM server    : ${GCM_SERVER_URL:-<not set>}"
    echo "  Results dir   : ${QSE_OUTPUT_BASE_DIR}"
    echo "  Commits dir   : ${LAST_COMMIT_BASE_DIR}"
    echo ""
    echo "  ACTIONS PER REPOSITORY:"
    echo "    1. Check remote Git repo for new commits since last scan"
    echo "    2. Clone latest commit of the repository"
    echo "    3. Detect languages and pre-compile where required"
    echo "    4. Run QSE cryptographic scan"
    echo "    5. Clean up cloned repository from local filesystem"
    echo "    6. Upload scan results to GCM via REST API"
    echo "    7. Save processed commit SHA to persistent storage"
    echo ""
    echo "  ⚠  Each cloned repository will be DELETED after its scan."
    echo "============================================================"
    echo ""

    local allow_file="${SCRIPT_DIR}/../.always_allow"
    if [[ "${ALWAYS_ALLOW:-false}" == "true" ]] || [[ -f "${allow_file}" ]]; then
        info "ALWAYS_ALLOW is set — skipping confirmation prompt."
        return 0
    fi

    if [[ ! -t 0 ]]; then
        info "Non-interactive session detected — skipping confirmation prompt."
        return 0
    fi

    read -r -p "Proceed? [y/N/always] " answer
    case "${answer}" in
        [Yy])   return 0 ;;
        always|ALWAYS)
            echo "true" > "${allow_file}"
            info "ALWAYS_ALLOW saved to ${allow_file}. Future runs will not prompt."
            return 0 ;;
        *)
            info "Aborted by user."
            exit 0 ;;
    esac
}

# ---- Validate required global env vars -- 2026-08-21 04:01:56 ---------------
validate_env() {
    local missing=0
    for var in GCM_SERVER_URL GCM_API_KEY; do
        if [[ -z "${!var:-}" ]]; then
            error "Required environment variable '${var}' is not set."
            missing=1
        fi
    done
    if [[ ! -f "${REPOS_FILE}" ]]; then
        error "Repos file not found: ${REPOS_FILE}"
        error "Mount the qse-pod-repos ConfigMap at /etc/qse-repos (see k8s/cronjob.yaml)."
        missing=1
    fi
    [[ "${missing}" -eq 0 ]] || { error "Aborting due to missing configuration."; exit 1; }
}

# ---- Parse repos.yaml into parallel arrays -- 2026-08-21 04:10:14 -----------
# Populates: REPO_URLS[], REPO_APP_NAMES[], REPO_EXCLUDES[]
# Uses only bash builtins + grep/sed — no yq/python required in the image.
parse_repos_file() {
    REPO_URLS=()
    REPO_APP_NAMES=()
    REPO_EXCLUDES=()

    local url="" app_name="" exclude_paths=""

    while IFS= read -r line; do
        # Strip leading whitespace for matching
        local trimmed="${line#"${line%%[![:space:]]*}"}"

        # New repo entry starts with "- url:"
        if [[ "${trimmed}" =~ ^-[[:space:]]+url:[[:space:]]*(.*) ]]; then
            # Save previous entry if url was set
            if [[ -n "${url}" ]]; then
                REPO_URLS+=("${url}")
                REPO_APP_NAMES+=("${app_name}")
                REPO_EXCLUDES+=("${exclude_paths}")
            fi
            url="${BASH_REMATCH[1]}"
            # Strip optional trailing comment
            url="${url%%#*}"
            url="${url%"${url##*[![:space:]]}"}"  # rtrim
            app_name=""
            exclude_paths=""

        elif [[ "${trimmed}" =~ ^app_name:[[:space:]]*(.*) ]]; then
            app_name="${BASH_REMATCH[1]%%#*}"
            app_name="${app_name%"${app_name##*[![:space:]]}"}"

        elif [[ "${trimmed}" =~ ^exclude_paths:[[:space:]]*(.*) ]]; then
            exclude_paths="${BASH_REMATCH[1]%%#*}"
            exclude_paths="${exclude_paths%"${exclude_paths##*[![:space:]]}"}"
        fi
    done < "${REPOS_FILE}"

    # Flush the last entry
    if [[ -n "${url}" ]]; then
        REPO_URLS+=("${url}")
        REPO_APP_NAMES+=("${app_name}")
        REPO_EXCLUDES+=("${exclude_paths}")
    fi

    if [[ "${#REPO_URLS[@]}" -eq 0 ]]; then
        error "No repositories found in ${REPOS_FILE}. Add at least one entry."
        exit 1
    fi

    info "Loaded ${#REPO_URLS[@]} repository/repositories from ${REPOS_FILE}."
}

# ---- Turn a repo URL into a safe filesystem slug -- 2026-08-21 04:10:14 -----
repo_slug() {
    local url="$1"
    # e.g. https://github.com/org/my-repo.git  →  org_my-repo
    local slug
    slug=$(echo "${url}" | sed 's|.*github[^/]*/||; s|\.git$||; s|/|_|g')
    echo "${slug}"
}

# ---- Inject credentials into HTTPS URL -- 2026-08-21 04:01:56 ---------------
build_auth_url() {
    local url="$1"
    if [[ -n "${GIT_TOKEN:-}" && "${url}" == https://* ]]; then
        local user="${GIT_USERNAME:-oauth2}"
        url="https://${user}:${GIT_TOKEN}@${url#https://}"
    fi
    echo "${url}"
}

# ---- Fetch HEAD SHA of remote repo -- 2026-08-21 04:01:56 -------------------
get_remote_head_sha() {
    local repo_url="$1"
    local auth_url
    auth_url=$(build_auth_url "${repo_url}")
    git ls-remote "${auth_url}" HEAD 2>/dev/null | awk '{print $1}'
}

# ---- Read last processed commit SHA for a repo -- 2026-08-21 04:10:14 -------
get_last_commit_sha() {
    local commit_file="$1"
    [[ -f "${commit_file}" ]] && cat "${commit_file}" || echo ""
}

# ---- Persist processed commit SHA for a repo -- 2026-08-21 04:10:14 ---------
save_last_commit_sha() {
    local sha="$1" commit_file="$2" slug="$3"
    mkdir -p "$(dirname "${commit_file}")"
    echo "${sha}" > "${commit_file}"
    info "Saved last processed commit for ${slug}: ${sha}"

    # Best-effort: patch the ConfigMap key "<slug>_last_sha" for visibility
    if command -v kubectl &>/dev/null \
            && [[ -n "${CONFIGMAP_NAME:-}" && -n "${CONFIGMAP_NAMESPACE:-}" ]]; then
        local cm_key="${slug}_last_sha"
        kubectl patch configmap "${CONFIGMAP_NAME}" \
            -n "${CONFIGMAP_NAMESPACE}" \
            --type merge \
            -p "{\"data\":{\"${cm_key}\":\"${sha}\"}}" 2>/dev/null \
            && info "ConfigMap '${CONFIGMAP_NAME}' updated: ${cm_key}=${sha}." \
            || warn "Could not update ConfigMap (non-fatal)."
    fi
}

# ---- Shallow-clone repo to a per-repo workspace dir -- 2026-08-21 04:10:14 --
clone_repo() {
    local repo_url="$1" workspace_dir="$2"
    local auth_url
    auth_url=$(build_auth_url "${repo_url}")
    info "Cloning (depth=1) to ${workspace_dir}..."
    rm -rf "${workspace_dir}"
    mkdir -p "${workspace_dir}"
    git clone --depth=1 "${auth_url}" "${workspace_dir}"
    # Remove credentials from local git config immediately
    git -C "${workspace_dir}" remote set-url origin "${repo_url}" 2>/dev/null || true
    info "Clone complete."
}

# ---- Clean up a single repo workspace -- 2026-08-21 04:10:14 ----------------
cleanup_repo() {
    local workspace_dir="$1"
    if [[ -d "${workspace_dir}" ]]; then
        info "Removing workspace: ${workspace_dir}"
        rm -rf "${workspace_dir}"
    fi
}

# ---- Inspect repo and set DETECTED_LANGUAGES + build flags -- 2026-08-21 04:01:56
# Sets globals: DETECTED_LANGUAGES[], NEEDS_JAVA_BUILD, NEEDS_GO_BUILD,
#               NEEDS_CPP_BUILD, NEEDS_DOTNET_BUILD, NEEDS_DART_BUILD
detect_languages() {
    local repo_dir="$1"
    DETECTED_LANGUAGES=()
    NEEDS_JAVA_BUILD=false
    NEEDS_GO_BUILD=false
    NEEDS_CPP_BUILD=false
    NEEDS_DOTNET_BUILD=false
    NEEDS_DART_BUILD=false

    if find "${repo_dir}" \( -name "*.java" -o -name "pom.xml" \
            -o -name "build.gradle" -o -name "build.gradle.kts" \) \
            2>/dev/null | grep -q .; then
        DETECTED_LANGUAGES+=(".java"); NEEDS_JAVA_BUILD=true
        info "Detected language: Java"
    fi

    if find "${repo_dir}" \( -name "*.go" -o -name "go.mod" \) \
            2>/dev/null | grep -q .; then
        DETECTED_LANGUAGES+=(".go"); NEEDS_GO_BUILD=true
        info "Detected language: Go"
    fi

    if find "${repo_dir}" \( -name "*.py" -o -name "requirements.txt" \
            -o -name "pyproject.toml" -o -name "setup.py" \) \
            2>/dev/null | grep -q .; then
        DETECTED_LANGUAGES+=(".py")
        info "Detected language: Python"
    fi

    if find "${repo_dir}" \( -name "*.cpp" -o -name "*.cc" -o -name "*.cxx" \
            -o -name "CMakeLists.txt" -o -name "Makefile" \) \
            2>/dev/null | grep -q .; then
        DETECTED_LANGUAGES+=(".cpp"); NEEDS_CPP_BUILD=true
        info "Detected language: C/C++"
    fi

    if find "${repo_dir}" \( -name "*.cs" -o -name "*.csproj" -o -name "*.sln" \) \
            2>/dev/null | grep -q .; then
        DETECTED_LANGUAGES+=(".cs"); NEEDS_DOTNET_BUILD=true
        info "Detected language: C#/.NET"
    fi

    if find "${repo_dir}" \( -name "*.dart" -o -name "pubspec.yaml" \) \
            2>/dev/null | grep -q .; then
        DETECTED_LANGUAGES+=(".dart"); NEEDS_DART_BUILD=true
        info "Detected language: Dart"
    fi

    if [[ "${#DETECTED_LANGUAGES[@]}" -eq 0 ]]; then
        warn "No recognised languages detected — falling back to all supported extensions."
        DETECTED_LANGUAGES=(".java" ".go" ".py" ".cpp" ".cs" ".dart")
    fi

    info "Languages to scan: ${DETECTED_LANGUAGES[*]}"
}

# ---- Maven/Gradle/javac pre-compile -- 2026-08-21 04:01:56 ------------------
compile_java() {
    local repo_dir="$1"
    info "--- Java: pre-compilation ---"
    if [[ -f "${repo_dir}/pom.xml" ]]; then
        info "Maven project detected."
        mvn -f "${repo_dir}/pom.xml" clean install dependency:copy-dependencies \
            -DskipTests -q --batch-mode \
            || { error "Maven build failed."; return 1; }
    elif [[ -f "${repo_dir}/build.gradle" || -f "${repo_dir}/build.gradle.kts" ]]; then
        info "Gradle project detected."
        gradle -p "${repo_dir}" build -x test --no-daemon --quiet \
            || { error "Gradle build failed."; return 1; }
    else
        info "No build descriptor found — compiling with javac."
        local out_dir="${repo_dir}/target/classes"
        mkdir -p "${out_dir}"
        find "${repo_dir}" -name "*.java" -print0 \
            | xargs -0 javac -d "${out_dir}" 2>/dev/null \
            || warn "javac errors — partial class files may exist."
    fi
    info "Java compilation complete."
}

# ---- go build pre-compile -- 2026-08-21 04:01:56 ----------------------------
compile_go() {
    local repo_dir="$1"
    info "--- Go: pre-compilation ---"
    if [[ -f "${repo_dir}/go.mod" ]]; then
        info "go.mod detected — running go build ./..."
        ( cd "${repo_dir}" && go build ./... ) \
            || warn "Go build errors — QSE will scan source directly."
    else
        info "No go.mod — scanning source files directly."
    fi
    info "Go compilation done."
}

# ---- CMake or make pre-compile -- 2026-08-21 04:01:56 -----------------------
compile_cpp() {
    local repo_dir="$1"
    info "--- C/C++: pre-compilation ---"
    if [[ -f "${repo_dir}/CMakeLists.txt" ]]; then
        local build_dir="${repo_dir}/build"
        mkdir -p "${build_dir}"
        cmake -S "${repo_dir}" -B "${build_dir}" -DCMAKE_BUILD_TYPE=Release -Wno-dev \
            && cmake --build "${build_dir}" --parallel "$(nproc)" \
            || warn "CMake errors — QSE will scan source files."
    elif [[ -f "${repo_dir}/Makefile" ]]; then
        ( cd "${repo_dir}" && make -j"$(nproc)" ) \
            || warn "make errors — QSE will scan source files."
    else
        info "No CMake/Makefile — QSE will scan source files directly."
    fi
    info "C/C++ compilation done."
}

# ---- dotnet build pre-compile -- 2026-08-21 04:01:56 ------------------------
compile_dotnet() {
    local repo_dir="$1"
    info "--- C#/.NET: pre-compilation ---"
    local proj_file
    proj_file=$(find "${repo_dir}" -maxdepth 3 \
        \( -name "*.sln" -o -name "*.csproj" \) | head -1)
    if [[ -n "${proj_file}" ]]; then
        dotnet build "${proj_file}" --configuration Release --no-restore -v quiet \
            || warn "dotnet build errors — QSE will scan source files."
    else
        info "No .sln/.csproj found — QSE will scan source files directly."
    fi
    info ".NET compilation done."
}

# ---- dart pub get dependency fetch -- 2026-08-21 04:01:56 -------------------
compile_dart() {
    local repo_dir="$1"
    info "--- Dart: dependency resolution ---"
    if [[ -f "${repo_dir}/pubspec.yaml" ]]; then
        ( cd "${repo_dir}" && dart pub get ) \
            || warn "dart pub get failed — QSE will scan source files."
    fi
    info "Dart dependency step done."
}

# ---- Build the comma-separated -l flag value -- 2026-08-21 04:01:56 ---------
build_language_flag() {
    local IFS=','
    echo "${DETECTED_LANGUAGES[*]}"
}

# ---- Build -cf value from compiled Java artefact dirs -- 2026-08-21 04:01:56
build_java_cf_flag() {
    local repo_dir="$1"
    local cf_parts=()
    [[ -d "${repo_dir}/target/classes" ]]    && cf_parts+=("${repo_dir}/target/classes")
    [[ -d "${repo_dir}/target/dependency" ]] && cf_parts+=("${repo_dir}/target/dependency")
    [[ -d "${repo_dir}/build/classes" ]]     && cf_parts+=("${repo_dir}/build/classes")
    [[ -d "${repo_dir}/build/libs" ]]        && cf_parts+=("${repo_dir}/build/libs")
    if [[ "${#cf_parts[@]}" -gt 0 ]]; then
        local IFS=';'
        echo "${cf_parts[*]}"
    fi
}

# ---- Run the QSE CLI with all detected language flags -- 2026-08-21 04:01:56
run_qse_scan() {
    local repo_dir="$1" output_dir="$2" app_name="$3" repo_url="$4"
    local app_version="${APP_VERSION:-$(git -C "${repo_dir}" rev-parse --short HEAD 2>/dev/null || echo "unknown")}"
    local lang_flag
    lang_flag=$(build_language_flag)

    info "Starting QSE scan..."
    info "  App      : ${app_name} @ ${app_version}"
    info "  Languages: ${lang_flag}"
    info "  Input    : ${repo_dir}"
    info "  Output   : ${output_dir}"

    mkdir -p "${output_dir}"

    local cli_args=(
        -i       "${repo_dir}"       # input folder
        -l       "${lang_flag}"      # language extensions to scan
        -o       "${output_dir}"     # output folder
        -app     "${app_name}"       # application name label
        -app_ver "${app_version}"    # version label
        -log                         # enable detailed log output
    )

    if [[ -n "${CURRENT_EXCLUDE_PATHS:-}" ]]; then
        cli_args+=(-ef "${CURRENT_EXCLUDE_PATHS}")
        info "  Exclusions: ${CURRENT_EXCLUDE_PATHS}"
    fi

    # Java: enable Usage Analysis (-da) and supply class/dep paths (-cf)
    if [[ "${NEEDS_JAVA_BUILD}" == "true" ]]; then
        local cf_flag
        cf_flag=$(build_java_cf_flag "${repo_dir}")
        if [[ -n "${cf_flag}" ]]; then
            cli_args+=(-da -cf "${cf_flag}")
            info "  Java -cf : ${cf_flag}"
        fi
    fi

    # Dart: enable exact package name matching (-em true)
    if [[ "${NEEDS_DART_BUILD}" == "true" ]]; then
        cli_args+=(-em true)
    fi

    info "Executing: ${QSE_CLI} ${cli_args[*]}"
    "${QSE_CLI}" "${cli_args[@]}"
    local rc=$?
    [[ "${rc}" -ne 0 ]] && { error "QSE CLI exited with code ${rc}"; return "${rc}"; }
    info "QSE scan completed. Results: ${output_dir}"
}

# ---- Grep results for known weak algorithms -- 2026-08-21 04:01:56 ----------
check_critical_findings() {
    local output_dir="$1"
    info "Checking results for critical cryptographic findings..."
    if find "${output_dir}" -name "*.json" \
            | xargs grep -l "MD5\|SHA-1\|DES\|RC4\|RSA-1024" 2>/dev/null \
            | grep -q .; then
        warn "⚠  Critical findings detected (MD5/SHA-1/DES/RC4/RSA-1024). Review: ${output_dir}"
    else
        info "No critical cryptographic findings."
    fi
}

# ---- POST scan results to GCM with retry/backoff -- 2026-08-21 04:01:56 -----
# ASSUMPTIONS (adjust when official GCM API spec is available):
#   Endpoint : POST ${GCM_SERVER_URL}/api/v1/scans
#   Auth     : X-API-Key header
#   Body     : multipart/form-data — field "results" (JSON file) + metadata
#   Success  : HTTP 2xx
#   Retry    : exponential backoff on 5xx; no retry on 4xx
upload_to_gcm() {
    local output_dir="$1" app_name="$2" app_version="${APP_VERSION:-unknown}"
    local endpoint="${GCM_SERVER_URL%/}/api/v1/scans"

    local result_file
    result_file=$(find "${output_dir}" -name "*.json" | head -1)
    if [[ -z "${result_file}" ]]; then
        error "No JSON result file found in ${output_dir}."
        return 1
    fi

    info "Uploading to GCM: ${endpoint}"
    info "Result file: ${result_file}"

    local attempt=0 delay="${RETRY_BASE_DELAY}" http_code

    while [[ "${attempt}" -lt "${MAX_RETRIES}" ]]; do
        attempt=$(( attempt + 1 ))
        info "GCM upload attempt ${attempt}/${MAX_RETRIES}..."

        local resp_file
        resp_file=$(mktemp)

        http_code=$(curl --silent --show-error \
            --write-out "%{http_code}" \
            --output "${resp_file}" \
            --max-time 120 \
            -X POST "${endpoint}" \
            -H "X-API-Key: ${GCM_API_KEY}" \
            -F "results=@${result_file};type=application/json" \
            -F "app_name=${app_name}" \
            -F "app_version=${app_version}" \
        )
        local curl_rc=$? resp_body
        resp_body=$(cat "${resp_file}"); rm -f "${resp_file}"

        if [[ "${curl_rc}" -ne 0 ]]; then
            warn "curl error (exit ${curl_rc}) on attempt ${attempt}."
        elif [[ "${http_code}" =~ ^2 ]]; then
            info "GCM upload successful (HTTP ${http_code})."
            return 0
        elif [[ "${http_code}" =~ ^4 ]]; then
            error "GCM client error HTTP ${http_code}: ${resp_body}"
            error "Not retrying 4xx errors."
            return 1
        else
            warn "GCM returned HTTP ${http_code}: ${resp_body}"
        fi

        if [[ "${attempt}" -lt "${MAX_RETRIES}" ]]; then
            info "Retrying in ${delay}s..."
            sleep "${delay}"
            delay=$(( delay * 2 ))
        fi
    done

    error "GCM upload failed after ${MAX_RETRIES} attempts."
    return 1
}

# ---- Scan a single repository -- 2026-08-21 04:10:14 ------------------------
# Runs the full 7-step scan lifecycle for one repo entry.
# Uses a per-repo cleanup trap so failure in one repo doesn't skip others.
scan_repo() {
    local repo_url="$1" app_name="$2" exclude_paths="$3"
    local slug
    slug=$(repo_slug "${repo_url}")

    local workspace_dir="${WORKSPACE_ROOT}/${slug}"
    local output_dir="${QSE_OUTPUT_BASE_DIR}/${slug}"
    local commit_file="${LAST_COMMIT_BASE_DIR}/${slug}.sha"

    # Per-repo effective exclusions: use repo-specific if set, else global default
    CURRENT_EXCLUDE_PATHS="${exclude_paths:-${EXCLUDE_PATHS:-}}"

    info "----------------------------------------------"
    info "Scanning: ${repo_url}"
    info "  Slug   : ${slug}"
    info "  App    : ${app_name}"
    info "  Output : ${output_dir}"
    info "----------------------------------------------"

    # Step 1 — check for new commits
    info "Step 1/7: Checking for new commits..."
    local remote_sha last_sha
    remote_sha=$(get_remote_head_sha "${repo_url}")
    last_sha=$(get_last_commit_sha "${commit_file}")

    if [[ -z "${remote_sha}" ]]; then
        error "Could not retrieve remote HEAD SHA for ${repo_url}. Skipping."
        return 1
    fi

    info "  Remote HEAD : ${remote_sha}"
    info "  Last scanned: ${last_sha:-<none — first run>}"

    if [[ "${remote_sha}" == "${last_sha}" ]]; then
        info "No new commits for ${app_name}. Skipping."
        return 0
    fi
    info "New commit detected: ${remote_sha}"

    # Step 2 — clone (cleaned up in the finally-equivalent block below)
    info "Step 2/7: Cloning repository..."
    clone_repo "${repo_url}" "${workspace_dir}"

    # Steps 3-7 run inside a subshell-style block so we can guarantee cleanup
    # even if any step returns non-zero (set -e is active)
    local scan_ok=true
    {
        # Step 3 — detect languages and pre-compile
        info "Step 3/7: Detecting languages and pre-compiling..."
        detect_languages "${workspace_dir}"
        [[ "${NEEDS_JAVA_BUILD}"   == "true" ]] && compile_java   "${workspace_dir}"
        [[ "${NEEDS_GO_BUILD}"     == "true" ]] && compile_go     "${workspace_dir}"
        [[ "${NEEDS_CPP_BUILD}"    == "true" ]] && compile_cpp    "${workspace_dir}"
        [[ "${NEEDS_DOTNET_BUILD}" == "true" ]] && compile_dotnet "${workspace_dir}"
        [[ "${NEEDS_DART_BUILD}"   == "true" ]] && compile_dart   "${workspace_dir}"

        # Step 4 — QSE scan
        info "Step 4/7: Running QSE cryptographic scan..."
        run_qse_scan "${workspace_dir}" "${output_dir}" "${app_name}" "${repo_url}"

    } || scan_ok=false

    # Step 5 — cleanup workspace regardless of scan outcome
    info "Step 5/7: Cleaning up repo workspace..."
    cleanup_repo "${workspace_dir}"

    if [[ "${scan_ok}" == "false" ]]; then
        error "Scan failed for ${app_name} (${repo_url}). Skipping upload and SHA save."
        return 1
    fi

    # Step 6 — check findings and upload
    info "Step 6/7: Checking findings and uploading to GCM..."
    check_critical_findings "${output_dir}"
    upload_to_gcm "${output_dir}" "${app_name}" || {
        error "GCM upload failed for ${app_name}. SHA will NOT be saved."
        return 1
    }

    # Step 7 — persist commit SHA only after successful upload
    info "Step 7/7: Persisting processed commit SHA..."
    save_last_commit_sha "${remote_sha}" "${commit_file}" "${slug}"

    info "Completed: ${app_name}"
}

# ---- Entry point -- 2026-08-21 04:01:56 -------------------------------------
main() {
    validate_env
    parse_repos_file

    confirm_execution "${#REPO_URLS[@]}"

    info "=========================================="
    info "QSE Pod scan job starting"
    info "Repositories to process: ${#REPO_URLS[@]}"
    info "=========================================="

    local total="${#REPO_URLS[@]}"
    local success=0 skipped=0 failed=0

    for (( i=0; i<total; i++ )); do
        local url="${REPO_URLS[$i]}"
        local app_name="${REPO_APP_NAMES[$i]:-$(basename "${url}" .git)}"
        local excludes="${REPO_EXCLUDES[$i]:-}"

        # Fill in app_name from URL if blank
        [[ -z "${app_name}" ]] && app_name=$(basename "${url}" .git)

        info ""
        info "========== Repo $((i+1))/${total}: ${app_name} =========="

        if scan_repo "${url}" "${app_name}" "${excludes}"; then
            success=$(( success + 1 ))
        else
            # Distinguish "skipped (no new commits)" vs actual failure
            # scan_repo returns 0 for both success and no-new-commits,
            # so a non-zero return here always means a real failure.
            failed=$(( failed + 1 ))
            warn "Repo ${app_name} failed. Continuing with remaining repos."
        fi
    done

    info ""
    info "=========================================="
    info "QSE Pod scan job complete."
    info "  Total     : ${total}"
    info "  Succeeded : ${success}"
    info "  Failed    : ${failed}"
    info "=========================================="

    # Exit non-zero if any repo failed so the CronJob marks the run as failed
    [[ "${failed}" -eq 0 ]] || exit 1
}

main "$@"
