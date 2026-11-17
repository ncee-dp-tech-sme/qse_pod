#!/usr/bin/env bash
# =============================================================================
# setup-github-config.sh - Set the GitHub Actions secrets and variables that
# the QSE scan workflow (qse-scan.yml) needs, from a local KEY=VALUE file.
#
# Run it from inside (or point it at) the repository that uses qse-scan.yml.
# It uses the GitHub CLI (`gh`), so you must be logged in (`gh auth login`)
# with rights to manage Actions secrets/variables on that repository.
#
# Usage:
#   setup-github-config.sh [--repo OWNER/REPO] [--env-file FILE]
#                          [--dry-run] [--remove] [--yes] [-h|--help]
#
# Environment variables (all optional; flags win over env):
#   GITHUB_REPO       Target repository, OWNER/REPO. Default: repo of the
#                     current directory (gh repo view)
#   QSE_CONFIG_FILE   Input file. Default: ./.qse-github.env
#   ALWAYS_ALLOW      "true" to skip the confirmation prompt
#   LOG_LEVEL         DEBUG | INFO | WARN | ERROR. Default: INFO
#
# Input file: KEY=VALUE per line, '#' comment lines, optional quotes, and a
# trailing " # comment" on unquoted values.
# See qse-github.env.example. Values are NEVER printed or put on a command line;
# they are piped to `gh` on stdin.
#
# Changes:
#   2026-11-17 01:27:10 - Initial creation
#   2026-11-17 02:26:33 - Auth check limited to the target host (a stale login on another host no longer fails it)
# =============================================================================

set -euo pipefail

# ---- Constants ---------------------------------------------------------------
readonly TIMESTAMP_FORMAT='%Y-%m-%dT%H:%M:%S%z'
readonly DEFAULT_ENV_FILE=".qse-github.env"
readonly ALLOW_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/qse-github-setup/always_allow"

# Names the workflow reads. Anything else in the input file is skipped.
readonly SECRET_KEYS="QSE_TOKEN GCM_BEARER_TOKEN"
readonly VARIABLE_KEYS="QSE_REPO_URL QSE_CLI_SUBDIR QSE_CLI_REF QSE_GIT_USERNAME \
QSE_APP_NAME APP_VERSION EXCLUDE_PATHS QSE_LANGUAGES PY_MODULE_PATH QSE_JAVA_VERSION \
GCM_UPLOAD_ENABLED GCM_SERVER_URL"

# ---- Logging: timestamped, to stderr, level from LOG_LEVEL -- 2026-11-17 01:27:10
_level_num() {
    case "$1" in
        DEBUG) echo 0 ;; INFO) echo 1 ;; WARN) echo 2 ;; ERROR) echo 3 ;; *) echo 1 ;;
    esac
}
log() {
    local level="$1"; shift
    [[ "$(_level_num "${level}")" -ge "$(_level_num "${LOG_LEVEL:-INFO}")" ]] || return 0
    printf '[%s] [%-5s] %s\n' "$(date +"${TIMESTAMP_FORMAT}")" "${level}" "$*" >&2
}
debug() { log DEBUG "$@"; }
info()  { log INFO  "$@"; }
warn()  { log WARN  "$@"; }
error() { log ERROR "$@"; }
die()   { error "$@"; exit 1; }

# ---- Print usage -- 2026-11-17 01:27:10 -------------------------------------
usage() {
    sed -n '2,/^# ====/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
}

# ---- Classify a key as secret / variable / unknown -- 2026-11-17 01:27:10 ---
classify_key() {
    local key="$1" k
    for k in ${SECRET_KEYS};   do [[ "${k}" == "${key}" ]] && { echo secret;   return; }; done
    for k in ${VARIABLE_KEYS}; do [[ "${k}" == "${key}" ]] && { echo variable; return; }; done
    echo unknown
}

# ---- Lower-case a string (bash 3.2 compatible) -- 2026-11-17 01:27:10 -------
to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---- Parse the input file into KEYS[] / VALUES[] without executing it -------
# 2026-11-17 01:27:10
parse_env_file() {
    local file="$1" line key val lineno=0 i found
    KEYS=(); VALUES=()
    while IFS= read -r line || [[ -n "${line}" ]]; do
        lineno=$(( lineno + 1 ))
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"          # ltrim
        [[ -z "${line}" || "${line}" == \#* ]] && continue

        if [[ ! "${line}" =~ ^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            warn "Line ${lineno}: not in KEY=VALUE format - skipped."
            continue
        fi
        key="${BASH_REMATCH[2]}"
        val="${BASH_REMATCH[3]}"
        val="${val#"${val%%[![:space:]]*}"}"             # ltrim
        val="${val%"${val##*[![:space:]]}"}"             # rtrim
        if [[ "${val}" =~ ^\"(.*)\"$ || "${val}" =~ ^\'(.*)\'$ ]]; then
            val="${BASH_REMATCH[1]}"
        else
            # Unquoted: strip a trailing " # comment" (whitespace before '#')
            val="$(printf '%s' "${val}" | sed -E 's/[[:space:]]+#.*$//')"
        fi

        found=-1
        for (( i=0; i<${#KEYS[@]}; i++ )); do
            if [[ "${KEYS[$i]}" == "${key}" ]]; then found="${i}"; fi
        done
        if [[ "${found}" -ge 0 ]]; then
            warn "Line ${lineno}: duplicate key ${key} - last value wins."
            VALUES[$found]="${val}"
        else
            KEYS+=("${key}"); VALUES+=("${val}")
        fi
    done < "${file}"
}

# ---- Look up a parsed value by key (empty if absent) -- 2026-11-17 01:27:10 -
value_of() {
    local key="$1" i
    for (( i=0; i<${#KEYS[@]}; i++ )); do
        if [[ "${KEYS[$i]}" == "${key}" ]]; then printf '%s' "${VALUES[$i]}"; return 0; fi
    done
    return 0
}

# ---- Reduce parsed pairs to the ones to apply: APPLY_KEYS[] -- 2026-11-17 01:27:10
# Skips unknown keys and empty values; rejects placeholder values.
select_keys() {
    local i key val bad=0
    APPLY_KEYS=()
    for (( i=0; i<${#KEYS[@]}; i++ )); do
        key="${KEYS[$i]}"; val="${VALUES[$i]}"
        if [[ "$(classify_key "${key}")" == unknown ]]; then
            warn "Key ${key} is not used by qse-scan.yml - skipped."
            continue
        fi
        if [[ -z "${val}" ]]; then
            debug "Key ${key} has an empty value - skipped."
            continue
        fi
        if [[ "${val}" =~ ^(your-|REPLACE_WITH|\<) ]]; then
            error "Key ${key} still has a placeholder value. Edit the file first."
            bad=1; continue
        fi
        APPLY_KEYS+=("${key}")
    done
    [[ "${bad}" -eq 0 ]] || exit 1
}

# ---- Validate the selected values like the workflow does -- 2026-11-17 01:27:10
validate_values() {
    local bad=0 v gcm k
    if [[ -z "$(value_of QSE_TOKEN)" ]]; then
        # Partial update: fine if the secret already exists in the repository
        if [[ "${DRY_RUN}" == false ]] \
                && gh secret list --repo "${REPO}" --json name -q '.[].name' | grep -qxF QSE_TOKEN; then
            info "QSE_TOKEN not in file - keeping the existing repository secret."
        else
            error "QSE_TOKEN is required (token to read the private QSE CLI repository)."
            bad=1
        fi
    fi
    for k in QSE_REPO_URL GCM_SERVER_URL; do
        v="$(value_of "${k}")"
        if [[ -n "${v}" && "${v}" != https://* ]]; then
            error "${k} must start with https://"; bad=1
        fi
    done
    v="$(value_of GCM_UPLOAD_ENABLED)"
    if [[ -n "${v}" ]]; then
        gcm="$(to_lower "${v}")"
        if [[ "${gcm}" != true && "${gcm}" != false ]]; then
            error "GCM_UPLOAD_ENABLED must be 'true' or 'false'."; bad=1
        elif [[ "${gcm}" == true ]]; then
            [[ -n "$(value_of GCM_SERVER_URL)"   ]] || { error "GCM_UPLOAD_ENABLED=true requires GCM_SERVER_URL."; bad=1; }
            [[ -n "$(value_of GCM_BEARER_TOKEN)" ]] || { error "GCM_UPLOAD_ENABLED=true requires GCM_BEARER_TOKEN."; bad=1; }
        fi
    fi
    [[ "${bad}" -eq 0 ]] || die "Validation failed - nothing was changed."
}

# ---- Warn on loose file permissions; keep the file out of git -- 2026-11-17 01:27:10
protect_env_file() {
    local file="$1" mode dir name
    mode="$(stat -c '%a' "${file}" 2>/dev/null || stat -f '%Lp' "${file}" 2>/dev/null || echo "")"
    if [[ -n "${mode}" && "${mode}" != 600 && "${mode}" != 400 ]]; then
        warn "${file} has mode ${mode}; it holds secrets. Run: chmod 600 ${file}"
    fi

    dir="$(cd "$(dirname "${file}")" && pwd)"; name="$(basename "${file}")"
    if git -C "${dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
            && ! git -C "${dir}" check-ignore -q "${name}" 2>/dev/null; then
        local top
        top="$(git -C "${dir}" rev-parse --show-toplevel)"
        printf '\n# Local QSE GitHub setup input (contains secrets)\n%s\n' "${name}" >> "${top}/.gitignore"
        warn "${name} was not git-ignored - added to ${top}/.gitignore so it cannot be committed."
    fi
}

# ---- Resolve target repo via gh -- 2026-11-17 01:27:10 ----------------------
resolve_repo() {
    if [[ -n "${REPO}" ]]; then return; fi
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
        || die "Could not detect the repository. Run inside a clone or pass --repo OWNER/REPO."
}

# ---- Show plan and ask for confirmation -- 2026-11-17 01:27:10 --------------
confirm_execution() {
    local action="$1" key
    echo "" >&2
    echo "============================================================" >&2
    echo "  QSE GitHub Actions configuration - ${action}" >&2
    echo "============================================================" >&2
    echo "  Repository : ${REPO}" >&2
    echo "  Input file : ${ENV_FILE}" >&2
    echo "  Items      :" >&2
    for key in "${APPLY_KEYS[@]}"; do
        printf '    - %-9s %s\n' "$(classify_key "${key}")" "${key}" >&2
    done
    if [[ "${action}" == REMOVE* ]]; then
        echo "  RISK: these secrets/variables will be DELETED from the repository." >&2
    else
        echo "  RISK: existing secrets/variables with the same names are OVERWRITTEN." >&2
        echo "        (Secret values cannot be read back, so they cannot be backed up.)" >&2
    fi
    echo "  Values are never printed. Rollback: run again with --remove." >&2
    echo "============================================================" >&2
    echo "" >&2

    if [[ "${ASSUME_YES}" == true || "${ALWAYS_ALLOW:-false}" == true ]]; then
        info "Confirmation skipped (--yes / ALWAYS_ALLOW)."; return 0
    fi
    if [[ -f "${ALLOW_FILE}" ]] && grep -qxF "${REPO}" "${ALLOW_FILE}" 2>/dev/null; then
        info "Confirmation skipped (always-allow stored for ${REPO})."; return 0
    fi
    if [[ ! -t 0 ]]; then
        info "Non-interactive session - skipping confirmation."; return 0
    fi

    local answer
    read -r -p "Proceed? [y/N/always] " answer
    case "${answer}" in
        [Yy]) return 0 ;;
        always|ALWAYS)
            mkdir -p "$(dirname "${ALLOW_FILE}")"
            echo "${REPO}" >> "${ALLOW_FILE}"
            info "Always-allow stored for ${REPO} in ${ALLOW_FILE}."
            return 0 ;;
        *) info "Aborted by user."; exit 0 ;;
    esac
}

# ---- Set one secret/variable; value goes to gh on stdin -- 2026-11-17 01:27:10
apply_one() {
    local key="$1" kind
    kind="$(classify_key "${key}")"
    if [[ "${DRY_RUN}" == true ]]; then
        info "[dry-run] would set ${kind} ${key}"; return 0
    fi
    if [[ "${key}" == GCM_UPLOAD_ENABLED ]]; then
        printf '%s' "$(to_lower "$(value_of "${key}")")" | gh variable set "${key}" --repo "${REPO}" >/dev/null
    else
        case "${kind}" in
            secret)   printf '%s' "$(value_of "${key}")" | gh secret   set "${key}" --repo "${REPO}" >/dev/null ;;
            variable) printf '%s' "$(value_of "${key}")" | gh variable set "${key}" --repo "${REPO}" >/dev/null ;;
        esac
    fi
    info "Set ${kind} ${key}"
}

# ---- Delete one secret/variable (rollback) -- 2026-11-17 01:27:10 -----------
remove_one() {
    local key="$1" kind
    kind="$(classify_key "${key}")"
    if [[ "${DRY_RUN}" == true ]]; then
        info "[dry-run] would delete ${kind} ${key}"; return 0
    fi
    if gh "${kind}" delete "${key}" --repo "${REPO}" >/dev/null 2>&1; then
        info "Deleted ${kind} ${key}"
    else
        warn "Could not delete ${kind} ${key} (not present or no permission)."
    fi
}

# ---- Confirm every applied name exists on GitHub -- 2026-11-17 01:27:10 -----
verify_applied() {
    local secrets vars key kind missing=0
    secrets="$(gh secret list   --repo "${REPO}" --json name -q '.[].name')"
    vars="$(gh variable list --repo "${REPO}" --json name -q '.[].name')"
    for key in "${APPLY_KEYS[@]}"; do
        kind="$(classify_key "${key}")"
        if [[ "${kind}" == secret ]]; then
            grep -qxF "${key}" <<<"${secrets}" || { error "Verify: secret ${key} not found."; missing=1; }
        else
            grep -qxF "${key}" <<<"${vars}"    || { error "Verify: variable ${key} not found."; missing=1; }
        fi
    done
    [[ "${missing}" -eq 0 ]] || die "Verification failed."
    info "Verified: all ${#APPLY_KEYS[@]} item(s) exist in ${REPO}."
}

# ---- Entry point -- 2026-11-17 01:27:10 -------------------------------------
main() {
    REPO="${GITHUB_REPO:-}"
    ENV_FILE="${QSE_CONFIG_FILE:-${DEFAULT_ENV_FILE}}"
    DRY_RUN=false; REMOVE=false; ASSUME_YES=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo)     [[ $# -ge 2 ]] || die "--repo needs a value"; REPO="$2"; shift 2 ;;
            --env-file) [[ $# -ge 2 ]] || die "--env-file needs a value"; ENV_FILE="$2"; shift 2 ;;
            --dry-run)  DRY_RUN=true; shift ;;
            --remove)   REMOVE=true; shift ;;
            --yes|-y)   ASSUME_YES=true; shift ;;
            -h|--help)  usage; exit 0 ;;
            *)          usage; die "Unknown argument: $1" ;;
        esac
    done

    [[ -f "${ENV_FILE}" ]] || die "Input file not found: ${ENV_FILE} (copy qse-github.env.example)."
    if [[ -n "${REPO}" && ! "${REPO}" =~ ^([A-Za-z0-9.-]+/)?[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        die "Invalid repository '${REPO}'. Expected OWNER/REPO."
    fi

    command -v gh >/dev/null 2>&1 || die "GitHub CLI 'gh' not found. Install it from https://cli.github.com/"
    if [[ "${DRY_RUN}" == false ]]; then
        local auth_host="${GH_HOST:-github.com}"
        if [[ "${REPO}" =~ ^([A-Za-z0-9.-]+)/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
            auth_host="${BASH_REMATCH[1]}"
        fi
        gh auth status --hostname "${auth_host}" >/dev/null 2>&1 \
            || die "gh is not authenticated for ${auth_host}. Run: gh auth login -h ${auth_host}"
    fi
    resolve_repo

    protect_env_file "${ENV_FILE}"
    parse_env_file "${ENV_FILE}"
    select_keys
    [[ "${#APPLY_KEYS[@]}" -gt 0 ]] || die "No usable KEY=VALUE entries found in ${ENV_FILE}."
    [[ "${REMOVE}" == true ]] || validate_values

    local action="APPLY"; [[ "${REMOVE}" == true ]] && action="REMOVE"
    [[ "${DRY_RUN}" == true ]] && action="${action} (dry-run)"
    confirm_execution "${action}"

    local key
    for key in "${APPLY_KEYS[@]}"; do
        if [[ "${REMOVE}" == true ]]; then remove_one "${key}"; else apply_one "${key}"; fi
    done

    if [[ "${DRY_RUN}" == false && "${REMOVE}" == false ]]; then
        verify_applied
        if [[ "$(to_lower "$(value_of GCM_UPLOAD_ENABLED)")" != true ]]; then
            info "GCM upload is OFF (GCM_UPLOAD_ENABLED is not 'true')."
        fi
    fi
    info "Done."
}

main "$@"
