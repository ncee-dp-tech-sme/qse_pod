# AGENTS.md

This file provides guidance to agents when working with code in this repository.

## Project shape
Bash + Kubernetes manifests only (no package manager, no test suite, no linter config). All logic is in [`scripts/scan.sh`](scripts/scan.sh); it runs as the container ENTRYPOINT (`/opt/qse-pod/scan.sh`) from a CronJob.

## Commands
- Syntax check / lint (only available checks): `bash -n scripts/scan.sh` and `shellcheck scripts/scan.sh` (if installed)
- Local run: copy `env.example` → `.env` (auto-sourced by `scan.sh` from `scripts/../.env`), create gitignored `repos-local.yaml` and set `REPOS_FILE=./repos-local.yaml`, then `ALWAYS_ALLOW=true bash scripts/scan.sh`. Requires `/opt/qse/cli.sh` (or `QSE_HOME`); `GCM_SERVER_URL` + `GCM_BEARER_TOKEN` are required only when `GCM_UPLOAD_ENABLED=true` (default `false`), otherwise `validate_env` aborts.
- There is no way to run a "single test". To exercise one repo, put only that repo in `repos-local.yaml`. Single function testing: `source` is unsafe (script calls `main "$@"` at EOF).
- Build image: `docker build --secret id=QSE_TOKEN,env=QSE_TOKEN -t <img> .` or `podman build --secret id=QSE_TOKEN,env=QSE_TOKEN -f Containerfile .` (QSE_TOKEN is mandatory; the QSE CLI is cloned from build arg `QSE_REPO_URL`, default `https://github.com/ncee-dp-tech-sme/qsecli.git`, and `cli.sh` is taken from build arg `QSE_CLI_SUBDIR`, default `CLI`; the build fails if `<subdir>/cli.sh` is missing).
- Deploy: `./install.sh --namespace qse-pod [--openshift] [--dry-run]`
- Manual scan: `kubectl create job --from=cronjob/qse-pod-scan manual-scan-$(date +%s) -n qse-pod`

## Non-obvious gotchas
- `examples/github-actions/.github/workflows/qse-scan.yml` is a copy-into-another-repo template and must NOT be moved to this repo's `.github/workflows/` (it would scan and commit into qse_pod). Keep its variables in sync with the README "GitHub Actions Workflow (Template)" section and with the key lists (`SECRET_KEYS`/`VARIABLE_KEYS`) in `examples/github-actions/setup-github-config.sh` and `qse-github.env.example`.
- `Dockerfile` and `Containerfile` are meant to be identical; the Containerfile is a mirrored copy, not a symlink. Edit both.
- `parse_repos_file` is a regex/grep parser, NOT a YAML parser (no yq/python in the runtime path). Only `- url:`, `app_name:`, `exclude_paths:` lines at any indent are recognized; trailing `# comments` are stripped. Do not introduce new YAML structure (multi-line values, anchors, nested keys) in `k8s/repos-configmap.yaml` without extending the parser.
- `repo_slug` only strips a `github*/` host prefix; non-GitHub URLs produce ugly/colliding slugs (slug is used for results dir, `<slug>.sha`, and ConfigMap key `<slug>_last_sha`).
- GCM upload is opt-in (`GCM_UPLOAD_ENABLED`, default `false`); when off, step 6 is skipped and results stay in `QSE_OUTPUT_BASE_DIR`. `k8s/cronjob.yaml` marks the `GCM_BEARER_TOKEN` secretKeyRef `optional: true`, and the key in `k8s/secret.yaml` is commented out (a `REPLACE_WITH` placeholder there would fail `install.sh`).
- Commit SHA is saved ONLY after a successful scan and, when upload is enabled, a successful GCM upload (step 7); a failed scan/upload re-runs on the next cron. "No new commits" returns 0 and counts as success.
- Per-repo failures never abort the loop; the script exits 1 at the end if any repo failed (marks the Job failed).
- `scan.sh` uses `set -euo pipefail`; step 3–4 are wrapped in `{ ... } || scan_ok=false` so the workspace is always cleaned. Note that `set -e` is suppressed inside that `||` group — failures in it do not abort early on their own, so use explicit `|| return` where needed.
- `SCAN_ALL_LANGUAGES` is documented/configured but not read by `scan.sh` (fallback to all extensions only happens when nothing is detected).
- `PY_MODULE_PATH` omitted → Python deps are pip-installed into `<repo>/.qse-venv`; keep `.qse-venv` in `EXCLUDE_PATHS`. Java `-da`/`-cf` are only added if compiled class dirs exist; `-cf` uses `;` as separator.
- GCM upload routing depends on exact QSE output filenames (`quantum_safe_api_discovery_findings.json`, `quantum_safe_cryptography_analysis_findings_*.json`; only the first analytics file via `head -1`). GCM auth requires BOTH `Authorization: Bearer` and `token_type: api_key` headers; 5xx retried (5/10/20s), 4xx not.
- `cronjob.yaml` `image:` is a placeholder; `readOnlyRootFilesystem: false` is deliberate (QSE CLI writes temp files). Container must stay UID 1001 / GID 0 group-writable for OpenShift arbitrary UIDs; do not hardcode `runAsUser`.
- The interactive confirmation prompt is skipped when `ALWAYS_ALLOW=true`, a `.always_allow` file exists (gitignored), or stdin is not a TTY (CronJob).

## Code style (observed conventions, also required by global rules)
- Bash must work on Bash and ZSH-hosted macOS/Linux; shebang `#!/usr/bin/env bash`, `set -euo pipefail`, `local` for function vars, `readonly` constants, `[[ ]]` tests.
- Every script has a header "Changes:" log (chronological, `YYYY-MM-DD HH:MM:SS - description`, timestamp from `date`); every new function gets a one-line comment above it `# ---- description -- <timestamp> ----`.
- Logging only via `info`/`warn`/`error` helpers (timestamped, to stderr). Never log `GCM_BEARER_TOKEN`/`GIT_TOKEN`; git auth URLs are built by `build_auth_url` and credentials removed after clone.
- Join arrays with `printf -v` (not `IFS` + `[*]`) — done deliberately to satisfy a semgrep IFS finding.
- User-provided values come from `.env`/env vars; add every new variable to `env.example` (secrets marked `# HashiCorpIgnore`), `k8s/configmap.yaml` or `k8s/secret.yaml`, the script header, and the README Configuration Reference.
- Compile helpers (`compile_*`) are best-effort: warn and continue. `compile_java` returns 1 on Maven/Gradle failure, but because of the `|| scan_ok=false` group above (errexit suppressed) the scan still proceeds.
- Completed tasks are archived under `task-outcomes/` (prompt first, then `date` timestamp) per global rules.
