# QSE Pod — Quantum Safe Explorer on Kubernetes & OpenShift

A containerised, scheduled workload that runs IBM's **Quantum Safe Explorer (QSE)** cryptographic scanner against **multiple Git repositories** and, optionally (disabled by default), uploads findings to **Guardium Cryptography Manager (GCM)**. Designed to run on both upstream Kubernetes (1.24+) and Red Hat OpenShift 4.x.

---
[QSE POD Github Repository](https://github.com/ncee-dp-tech-sme/qse_pod)
## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [How the Scan Flow Works](#how-the-scan-flow-works)
3. [Managing the Repository List](#managing-the-repository-list)
4. [Repository Structure](#repository-structure)
5. [Prerequisites](#prerequisites)
6. [Configuration Reference](#configuration-reference)
7. [Setting Up a Private GitHub Repository for the QSE CLI](#setting-up-a-private-github-repository-for-the-qse-cli)
8. [Building the Container Image](#building-the-container-image)
9. [Deploying to Kubernetes or OpenShift](#deploying-to-kubernetes-or-openshift)
10. [Monitoring and Troubleshooting](#monitoring-and-troubleshooting)
11. [QSE Flag Reference and Rationale](#qse-flag-reference-and-rationale)
12. [GCM API Reference](#gcm-api-reference)
13. [Security Design](#security-design)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Kubernetes / OpenShift Cluster                                  │
│                                                                  │
│  ┌──────────────┐   triggers   ┌───────────────────────────┐    │
│  │   CronJob    │─────────────▶│  qse-scanner Pod          │    │
│  │ (scheduled)  │              │  ┌─────────────────────┐  │    │
│  └──────────────┘              │  │  scan.sh            │  │    │
│                                │  │  1. Check commits   │  │    │
│  ┌──────────────┐              │  │  2. Clone repo      │  │    │
│  │  ConfigMap   │──env vars───▶│  │  3. Detect + build  │  │    │
│  └──────────────┘              │  │  4. QSE scan        │  │    │
│  ┌──────────────┐              │  │  5. Cleanup         │  │    │
│  │   Secret     │──env vars───▶│  │  6. Upload (opt.)   │  │    │
│  └──────────────┘              │  │  7. Save commit SHA │  │    │
│  ┌──────────────┐              │  └─────────────────────┘  │    │
│  │    PVC       │◀─results ────│                            │    │
│  └──────────────┘              └───────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
          │ upload results
          ▼
   Guardium Cryptography Manager (GCM) REST API
```

- The **CronJob** fires on a configurable schedule (default: every hour).
- The **Pod** runs `scan.sh`, which performs the full scan lifecycle.
- **Sensitive credentials** (Git token and, if GCM upload is enabled, the GCM Bearer token) are stored in a Kubernetes `Secret` and injected as environment variables — never hardcoded.
- Non-sensitive config (GCM upload switch, GCM URL, exclusions) lives in a `ConfigMap`.
- **GCM upload is optional and disabled by default** (`GCM_UPLOAD_ENABLED=false`).
- The **last processed commit SHA** is written to a `PersistentVolumeClaim` and optionally patched back into the `ConfigMap` for visibility.

---

## How the Scan Flow Works

Each time the CronJob Pod runs, `scan.sh` executes these 7 steps in order:

### Step 1 — Check for new commits
The script calls `git ls-remote` against the target repository to read its current `HEAD` SHA. It compares that against the SHA stored in `LAST_COMMIT_FILE` on the PVC. If the SHAs match, there is nothing new to scan and the pod exits cleanly with code `0`. If they differ, execution continues.

### Step 2 — Clone the repository
The latest commit is shallow-cloned (`--depth=1`) into a temporary workspace directory inside the container. If `GIT_TOKEN` is set, it is spliced into the HTTPS URL for authentication against private repositories. Credentials are immediately removed from the local git config after cloning.

### Step 3 — Detect languages and pre-compile
The script inspects file extensions and build descriptor files to determine which of QSE's supported languages are present. For each compiled language found, an appropriate build step is run so QSE can analyse the compiled artefacts:

| Language | Detection files | Build step |
|---|---|---|
| Java | `*.java`, `pom.xml`, `build.gradle` | `mvn install` / `gradle build` / `javac` |
| Go | `*.go`, `go.mod` | `go build ./...` |
| C/C++ | `*.cpp`, `*.cc`, `CMakeLists.txt`, `Makefile` | `cmake + make` / `make` |
| C# | `*.cs`, `*.csproj`, `*.sln` | `dotnet build` |
| Dart | `*.dart`, `pubspec.yaml` | `dart pub get` |
| Python | `*.py`, `requirements.txt`, `pyproject.toml`, `setup.py` | `pip install` into isolated venv (see [Python Dependency Handling](#python-dependency-handling)) |

### Python Dependency Handling

Before the QSE scan runs on a Python repository, `scan.sh` ensures all imports are resolvable using one of two strategies:

**Option 1 — Install dependencies in the project directory (default)**

The script automatically creates an isolated virtualenv at `<repo>/.qse-venv` and installs dependencies from `requirements.txt` and/or `setup.py` / `pyproject.toml` if present. The venv directory is excluded from the scan via `EXCLUDE_PATHS`. No manual steps are required.

**Option 2 — Specify an external module path**

If your dependencies are pre-installed in a separate location (e.g. a shared site-packages directory mounted into the container), set `PY_MODULE_PATH` in `k8s/configmap.yaml`:

```yaml
PY_MODULE_PATH: "/opt/site-packages"
```

This value is passed directly to the QSE CLI as `-py_module_path`. It can also point to a virtualenv's site-packages directory:

```yaml
PY_MODULE_PATH: "/opt/my-venv/lib/python3.11/site-packages"
```

Leave `PY_MODULE_PATH` empty (the default) to use Option 1.

### Step 4 — Run the QSE scan
`cli.sh` is executed with the flags appropriate for all detected languages. See [QSE Flag Reference](#qse-flag-reference-and-rationale) for the full flag rationale.

### Step 5 — Clean up the workspace
A `trap` on `EXIT INT TERM` guarantees the cloned repository is deleted from the container filesystem whether the scan succeeds, fails, or is interrupted. Nothing from the target repository persists in the container after the pod exits.

### Step 6 — Upload results to GCM (optional, off by default)
This step runs only when `GCM_UPLOAD_ENABLED=true`. By default it is skipped: the findings remain in `QSE_OUTPUT_BASE_DIR/<slug>/` on the PVC and no GCM URL or token is required. When enabled, the QSE findings files are uploaded to the GCM REST API via `curl`. The script auto-detects which output files are present and routes each to the correct endpoint:
- `quantum_safe_api_discovery_findings.json` → `POST /ibm/pv/api/v1/upload-qse-findings/discovery?repositoryUrl=…`
- `quantum_safe_cryptography_analysis_findings_*.json` → `POST /ibm/pv/api/v1/upload-qse-findings/analytics?repositoryUrl=…`

Authentication uses `Authorization: Bearer <GCM_BEARER_TOKEN>` + `token_type: api_key` headers. The token is **never logged**. Transient server errors (HTTP 5xx) are retried with exponential backoff (up to 3 attempts). Client errors (HTTP 4xx) fail immediately.

### Step 7 — Persist the commit SHA
The SHA is saved after a successful scan (and, when GCM upload is enabled, a successful upload).
The processed commit SHA is written per-repo to `LAST_COMMIT_BASE_DIR/<slug>.sha` on the PVC. Optionally, the ConfigMap is also patched via `kubectl patch` with a key per repo (`<slug>_last_sha`).

---

## Managing the Repository List

Repositories to scan are stored in the `qse-pod-repos` ConfigMap, defined in [`k8s/repos-configmap.yaml`](k8s/repos-configmap.yaml). This is the **only file you need to edit** to add, remove, or reconfigure repos. No pod restart or CronJob modification is required — the next scheduled run picks up the change automatically.

### Format

The ConfigMap contains a single key `repos.yaml` with this structure:

```yaml
repos:
  - url: https://github.com/your-org/repo-one.git
    app_name: repo-one                          # optional; defaults to repo name
    exclude_paths: src/test,vendor,node_modules # optional; overrides global EXCLUDE_PATHS

  - url: https://github.com/your-org/repo-two.git
    app_name: repo-two
    exclude_paths: src/test,vendor
```

| Field | Required | Description |
|---|---|---|
| `url` | **Yes** | HTTPS or SSH URL of the repository to scan |
| `app_name` | No | Label used in GCM results. Defaults to the repository name from the URL |
| `exclude_paths` | No | Comma-separated paths to exclude from the QSE scan for this repo. Overrides the global `EXCLUDE_PATHS` setting |

### Adding a repository

**Option 1 — Edit and re-apply the file (recommended for GitOps):**
```bash
# Edit k8s/repos-configmap.yaml, then:
kubectl apply -f k8s/repos-configmap.yaml -n qse-pod
```

**Option 2 — In-place edit via kubectl:**
```bash
kubectl edit configmap qse-pod-repos -n qse-pod
```
Add a new `- url:` block under `repos:`, save, and exit. The change takes effect on the next CronJob run.

### Per-repo isolation

Each repository gets its own isolated paths on the PVC:

| Path | Purpose |
|---|---|
| `/opt/qse-pod/results/scans/<slug>/` | QSE JSON scan results |
| `/opt/qse-pod/results/commits/<slug>.sha` | Last processed commit SHA |

The `slug` is derived from the repo URL (e.g. `your-org/repo-one.git` → `your-org_repo-one`).

### Credential sharing

All repositories share the same `GIT_TOKEN` / `GIT_USERNAME` from the `qse-pod-secrets` Secret. If your organisation uses a single service account or PAT with read access to all repos, this works out of the box. If different repos require different credentials, they should be deployed as separate QSE Pod instances in separate namespaces.

---

## Repository Structure

```
.
├── Dockerfile            # Multi-stage container image (Docker/containerd)
├── Containerfile         # Identical build for Podman/Buildah (OpenShift)
├── install.sh            # One-command deploy script for K8s and OpenShift
├── env.example           # Template for local .env configuration
├── scripts/
│   └── scan.sh           # Main scan orchestration script (loops over all repos)
└── k8s/
    ├── secret.yaml        # Secret template (fill in before applying)
    ├── configmap.yaml     # Global non-sensitive configuration
    ├── repos-configmap.yaml # ← ADD/REMOVE repos here
    ├── pvc.yaml           # PersistentVolumeClaim for results + state
    ├── serviceaccount.yaml # ServiceAccount + Role + RoleBinding
    ├── cronjob.yaml       # CronJob manifest
    └── scc.yaml           # OpenShift SecurityContextConstraints
```

---

## Prerequisites

| Tool | Purpose | Version |
|---|---|---|
| `docker` or `podman` | Build the container image | Any recent |
| `kubectl` | Deploy to Kubernetes | 1.24+ |
| `oc` | Deploy to OpenShift | 4.x |
| Access to the QSE CLI GitHub repo | Pull QSE CLI during image build | — |
| **QSE CLI repository** | Source of the Quantum Safe Explorer command-line scanner (`cli.sh`). A `QSE_TOKEN` (GitHub personal access token with `repo` scope, or a fine-grained token with read access to Contents) is required at image build time. The repository (`QSE_REPO_URL`) and the directory containing `cli.sh` (`QSE_CLI_SUBDIR`) are configurable build arguments. Contact your IBM representative to obtain access, or see [Setting Up a Private GitHub Repository for the QSE CLI](#setting-up-a-private-github-repository-for-the-qse-cli) to host your own copy. | — |
| GCM instance *(optional)* | Receive scan results when `GCM_UPLOAD_ENABLED=true` | — |

---

## Configuration Reference

All values are set in `k8s/configmap.yaml` (non-sensitive) and `k8s/secret.yaml` (sensitive). For local testing, copy `env.example` to `.env` and fill in values.

### ConfigMap values

| Key | Description | Default |
|---|---|---|
| `GCM_UPLOAD_ENABLED` | Set to `true` to upload findings to GCM after each scan. When `false`, results stay on the PVC and no GCM settings are needed | `false` |
| `GCM_SERVER_URL` | Base URL of the GCM server | *(required only when `GCM_UPLOAD_ENABLED=true`)* |
| `APP_VERSION` | Version label applied to all repos | auto: commit SHA |
| `EXCLUDE_PATHS` | Comma-separated paths excluded from scan | `src/test,vendor,node_modules,.git,venv,.qse-venv` |
| `PY_MODULE_PATH` | Optional path to pre-installed Python modules; passed as `-py_module_path` to QSE CLI (Option 2). Leave empty to auto-install via pip (Option 1) | `""` |
| `QSE_OUTPUT_BASE_DIR` | Base directory for QSE JSON results; sub-directories created per repo | `/opt/qse-pod/results/scans` |
| `LAST_COMMIT_BASE_DIR` | Base directory for per-repo last-commit SHA files | `/opt/qse-pod/results/commits` |
| `SCAN_ALL_LANGUAGES` | Force all languages regardless of detection | `false` |
| `REPOS_FILE` | Path where the repos ConfigMap is mounted | `/etc/qse-repos/repos.yaml` |
| `CONFIGMAP_NAME` | ConfigMap to patch with per-repo commit SHAs (optional) | — |
| `CONFIGMAP_NAMESPACE` | Namespace of above ConfigMap | — |

### Secret values

| Key | Description |
|---|---|
| `GCM_BEARER_TOKEN` | Bearer token for authenticating to GCM *(optional; required only when `GCM_UPLOAD_ENABLED=true`)* |
| `GIT_USERNAME` | Git username for private repositories |
| `GIT_TOKEN` | Git personal access token for private repositories |

---

## Setting Up a Private GitHub Repository for the QSE CLI

The image build clones the QSE CLI from a GitHub repository (`QSE_REPO_URL`) and copies the directory that contains `cli.sh` (`QSE_CLI_SUBDIR`) into the image. If you do not have access to an existing repository, you can host your own copy of the QSE CLI (the QLI download package of IBM program **M0R8BEN**) in a **private** GitHub repository and point the build at it.

> **Licensing:** The QSE CLI is IBM software. Keep the repository **private** and share it only with people entitled to use the program. Never make it public and never fork it into a public account.

### Overview

```
1. Create private repo  →  2. Create token  →  3. Upload QLI files  →  4. Verify
                                                                          ↓
                         6. Build image  ←  5. Configure build args + secret
```

### Step 1 — Create the private repository

1. Sign in to GitHub (or your GitHub Enterprise instance).
2. Click **+** (top right) → **New repository**.
3. Fill in the form:
   - **Owner**: your user or organisation.
   - **Repository name**: for example `qsecli`.
   - **Visibility**: select **Private**.
   - Leave **Add a README**, **.gitignore** and **license** *unchecked*. An empty repository makes the first upload simpler.
4. Click **Create repository**.
5. Copy the HTTPS clone URL shown on the next page, for example `https://github.com/<owner>/qsecli.git`. You will use this value as `QSE_REPO_URL`.

### Step 2 — Generate a personal access token (PAT)

A token is used for two purposes: (a) pushing the QLI files from your workstation and (b) cloning the repository during the image build (`QSE_TOKEN`).

#### Option A — Classic token with `repo` scope

1. GitHub → your avatar → **Settings** → **Developer settings** → **Personal access tokens** → **Tokens (classic)**.
2. Click **Generate new token** → **Generate new token (classic)**.
3. **Note**: `qse-cli-repo`.
4. **Expiration**: choose the shortest practical period (30–90 days).
5. **Scopes**: tick **`repo`** (full control of private repositories). No other scope is needed.
6. Click **Generate token** and copy it immediately. GitHub shows it only once.
7. If your organisation uses SAML SSO, click **Configure SSO** next to the token and **Authorize** the organisation.

#### Option B — Fine-grained token (preferred, least privilege)

1. **Settings** → **Developer settings** → **Personal access tokens** → **Fine-grained tokens** → **Generate new token**.
2. **Repository access**: **Only select repositories** → choose the QSE CLI repository.
3. **Repository permissions**: **Contents** → **Read and write** for the upload token, or **Read-only** for a separate build token.
4. Set a short expiration and generate the token.

> Recommended: use one token with write access for the one-off upload, then delete it. Use a second, read-only token (Option B) for image builds.

### Step 3 — Configure the token for authentication

Never put the token in a repository URL that is saved in `.git/config`, in shell history or in a file inside the repository.

**For the upload (Git credential prompt):** when `git push` asks for credentials, enter your GitHub username and paste the token as the **password**. To avoid retyping, enable your OS credential helper:

```bash
# macOS
git config --global credential.helper osxkeychain
# Linux (cache for 1 hour)
git config --global credential.helper 'cache --timeout=3600'
```

**For the upload (GitHub CLI alternative):**

```bash
gh auth login        # choose HTTPS and paste the token, or use the browser flow
```

**For the image build:** read the token into an environment variable without echoing it or storing it in history:

```bash
read -rs QSE_TOKEN && export QSE_TOKEN   # paste token, press Enter (input is hidden)
```

Alternatively store it in a file only you can read and pass it with `--secret id=QSE_TOKEN,src=<file>`:

```bash
umask 077 && mkdir -p ~/.secrets && read -rs t && printf '%s' "$t" > ~/.secrets/qse_token && unset t
```

### Step 4 — Upload the QLI files and keep the directory structure

1. Unpack the QLI download package from IBM (program M0R8BEN) into a working folder, for example `~/qse-download`. Check that `cli.sh` is present and note where it is located (root or sub-directory).
2. Decide the layout in the repository:

   | Layout in repository | `QSE_CLI_SUBDIR` |
   |---|---|
   | `cli.sh` in the repository root | `.` |
   | `CLI/cli.sh` (same layout as the default repository) | `CLI` |

3. Upload with Git (recommended). Git preserves all sub-directories, hidden files and file modes exactly as they are on disk.

   ```bash
   # Option 1: files go into a CLI/ sub-directory (QSE_CLI_SUBDIR=CLI)
   mkdir -p ~/qsecli-repo/CLI
   cp -R ~/qse-download/. ~/qsecli-repo/CLI/

   # Option 2: files go into the repository root (QSE_CLI_SUBDIR=.)
   # mkdir -p ~/qsecli-repo && cp -R ~/qse-download/. ~/qsecli-repo/

   cd ~/qsecli-repo
   git init -b main
   git add --all                      # includes every file, sub-directory and dotfile
   git status --short | head -20      # review what will be committed
   git commit -m "Add QSE CLI (IBM M0R8BEN) files"
   git remote add origin https://github.com/<owner>/qsecli.git
   git push -u origin main
   ```

   Notes:
   - Use `cp -R <dir>/.` (with the trailing `/.`) so hidden files are copied too.
   - Git does not store **empty directories**. If a directory must exist but is empty, add an empty `.gitkeep` file to it.
   - GitHub rejects single files larger than 100 MB and warns above 50 MB. For files above these limits, contact your IBM representative or use [Git LFS](https://git-lfs.com/). Note that `git clone --depth=1` in the Dockerfile fetches LFS pointers only unless `git-lfs` is installed in the builder stage.
   - Do not commit unrelated files such as downloaded license keys, `.env` files or tokens.

4. Browser upload (only for small packages): open the repository → **Add file** → **Upload files** and drag the **folders** (not just their contents) into the page. This keeps the directory structure, but is limited to 100 files per upload and 25 MB per file and does not set the executable bit. The Dockerfile runs `chmod +x /opt/qse/*.sh`, so this is acceptable. For large packages with many sub-directories, use Git.

### Step 5 — Verify the upload

Perform all three checks before building the image.

1. **Compare file counts** between the source and what Git tracks:

   ```bash
   cd ~/qse-download && find . -type f | wc -l
   cd ~/qsecli-repo  && git ls-files CLI | wc -l      # use `git ls-files | wc -l` for the root layout
   ```

2. **Clone fresh and diff** against the original download (no output means identical):

   ```bash
   cd "$(mktemp -d)"
   git clone --depth=1 https://github.com/<owner>/qsecli.git verify    # authenticate when prompted
   diff -r --exclude=.git verify/CLI ~/qse-download && echo "Identical"
   ```

3. **Confirm `cli.sh` exists at the expected path**, the same check the Dockerfile performs:

   ```bash
   test -f verify/CLI/cli.sh && echo "cli.sh found"
   ```

You can also browse the repository on GitHub and confirm the sub-directories appear and that the repository shows the **Private** badge.

### Step 6 — Integrate with the Dockerfile / Containerfile

`Dockerfile` and `Containerfile` already support a private repository, so no file edits are needed. Pass the repository URL and sub-directory as build arguments and the token as a build secret:

| Input | Value for the private repository | How it is passed |
|---|---|---|
| `QSE_REPO_URL` | `https://github.com/<owner>/qsecli.git` | `--build-arg` (no credentials in the URL) |
| `QSE_CLI_SUBDIR` | `CLI` (or `.` for the repository root) | `--build-arg` |
| `QSE_TOKEN` | Your PAT | `--secret id=QSE_TOKEN,env=QSE_TOKEN` or `src=<file>` |

**Example 1 — `cli.sh` in a `CLI/` sub-directory (Docker):**

```bash
read -rs QSE_TOKEN && export QSE_TOKEN

docker build \
  --secret id=QSE_TOKEN,env=QSE_TOKEN \
  --build-arg QSE_REPO_URL=https://github.com/<owner>/qsecli.git \
  --build-arg QSE_CLI_SUBDIR=CLI \
  -t your-registry.example.com/qse-pod:latest .
```

**Example 2 — `cli.sh` in the repository root (Podman, token read from a file):**

```bash
podman build \
  --secret id=QSE_TOKEN,src=$HOME/.secrets/qse_token \
  --build-arg QSE_REPO_URL=https://github.com/<owner>/qsecli.git \
  --build-arg QSE_CLI_SUBDIR=. \
  -t your-registry.example.com/qse-pod:latest \
  -f Containerfile .
```

**Example 3 — GitHub Enterprise Server:**

```bash
docker build \
  --secret id=QSE_TOKEN,env=QSE_TOKEN \
  --build-arg QSE_REPO_URL=https://github.example.com/<owner>/qsecli.git \
  --build-arg QSE_CLI_SUBDIR=CLI \
  -t your-registry.example.com/qse-pod:latest .
```

How it works at build time: the builder stage rewrites the URL to `https://<token>@<host>/<path>`, clones with `--depth=1`, verifies `<QSE_CLI_SUBDIR>/cli.sh`, copies the directory to `/opt/qse` and deletes the clone. The token is read from the secret mount, is not stored in image layers and is **not present in the runtime image**. The running CronJob does not need `QSE_TOKEN`.

If the build fails, check the following:

| Symptom | Likely cause |
|---|---|
| `Authentication failed` / `Repository not found` | Token expired, lacks `repo` scope (classic) or Contents access to this repository (fine-grained), SSO not authorised, or URL typo |
| `test -f .../cli.sh` fails | Wrong `QSE_CLI_SUBDIR`, or files were uploaded one directory level too deep |
| `secret QSE_TOKEN not found` | `QSE_TOKEN` is not exported, or `--secret` flag is missing |

### Security best practices for token management

- **Least privilege**: prefer a fine-grained token limited to this single repository; use `repo` (classic) only when fine-grained tokens are unavailable.
- **Separate tokens**: one short-lived write token for the upload (delete it afterwards) and one read-only token for builds.
- **Expiration and rotation**: set an expiry of 90 days or less and rotate on schedule. After rotation, update the CI secret store and delete the old token.
- **Never commit tokens**: keep them out of Git, `.env` files in version control, Dockerfiles and `--build-arg` values (build args are visible in `docker history`). Always use `--secret`.
- **Avoid shell history leaks**: use `read -rs` instead of `export QSE_TOKEN=ghp_...` on the command line. Prefix a command with a space only if `HISTCONTROL=ignorespace` is set. <!-- HashiCorpIgnore -->
- **Don't embed the token in remotes**: do not run `git remote add origin https://<token>@github.com/...`; this stores the token in `.git/config` in clear text.
- **Protect token files**: `chmod 600` the file (or `umask 077` when creating it) and keep it outside any Git working tree.
- **CI/CD**: store the token in the CI system's secret store (for example GitHub Actions secrets) and inject it only into the build step.
- **Restrict access**: grant repository access only to people who are licensed to use the QSE CLI, and enable 2FA on all accounts.
- **If a token leaks**: revoke it immediately under **Settings** → **Developer settings**, create a new one and review the repository **audit log** for unexpected access.

---

## Building the Container Image

The image build requires a `QSE_TOKEN` (GitHub access token for the QSE CLI repository, passed as a build secret). The location of `cli.sh` is configured with two build arguments:

| Build argument | Description | Default |
|---|---|---|
| `QSE_REPO_URL` | HTTPS URL of the GitHub repository that holds the QSE CLI | `https://github.com/ncee-dp-tech-sme/qsecli.git` |
| `QSE_CLI_SUBDIR` | Directory inside that repository containing `cli.sh` (`.` if it is in the repo root) | `CLI` |

The build fails if `<QSE_CLI_SUBDIR>/cli.sh` does not exist in the cloned repository. Only `https://` URLs are supported (the token is injected into the URL).

### Docker

```bash
export QSE_TOKEN=your_github_token

docker build \
  --secret id=QSE_TOKEN,env=QSE_TOKEN \
  --build-arg QSE_REPO_URL=https://github.com/ncee-dp-tech-sme/qsecli.git \
  --build-arg QSE_CLI_SUBDIR=CLI \
  -t your-registry.example.com/qse-pod:latest .
```

### Podman / Buildah (OpenShift)

```bash
export QSE_TOKEN=your_github_token

podman build \
  --secret id=QSE_TOKEN,env=QSE_TOKEN \
  --build-arg QSE_REPO_URL=https://github.com/ncee-dp-tech-sme/qsecli.git \
  --build-arg QSE_CLI_SUBDIR=CLI \
  -t your-registry.example.com/qse-pod:latest \
  -f Containerfile .
```

### Push the image

```bash
docker push your-registry.example.com/qse-pod:latest
# or
podman push your-registry.example.com/qse-pod:latest
```

> After pushing, update the `image:` field in `k8s/cronjob.yaml` to your registry path.

---

## Deploying to Kubernetes or OpenShift

### Step 1 — Configure secrets

Edit `k8s/secret.yaml` and replace all `REPLACE_WITH_*` placeholder values with your real credentials. **Do not commit this file to source control after filling it in.**

```yaml
stringData:
  GIT_USERNAME: "your-git-username"
  GIT_TOKEN: "your-git-personal-access-token"
  # Only when GCM upload is enabled (GCM_UPLOAD_ENABLED: "true"):
  # GCM_BEARER_TOKEN: "your-real-gcm-bearer-token"
```

### Step 2 — Configure GCM upload (optional) and Python module path (optional)

Edit `k8s/configmap.yaml`. GCM upload is **off by default**; to enable it, set `GCM_UPLOAD_ENABLED: "true"`, set `GCM_SERVER_URL`, and add `GCM_BEARER_TOKEN` to the Secret in Step 1.

```yaml
data:
  GCM_UPLOAD_ENABLED: "false"          # "true" to upload findings to GCM
  GCM_SERVER_URL: "https://gcm.your-domain.com"   # used only when upload is enabled
  # Optional: set to a pre-installed Python modules path (Option 2).
  # Leave empty to auto-install Python deps via pip (Option 1, default).
  PY_MODULE_PATH: ""
```

Then add your repositories to `k8s/repos-configmap.yaml` (see [Managing the Repository List](#managing-the-repository-list)).

### Step 3 — Update the image reference

In `k8s/cronjob.yaml`, update:
```yaml
image: your-registry.example.com/qse-pod:latest
```

### Step 4 — Deploy with install.sh

**Kubernetes:**
```bash
chmod +x install.sh
./install.sh --namespace qse-pod
```

**OpenShift** (also applies the SCC, requires `cluster-admin`):
```bash
./install.sh --namespace qse-pod --openshift
```

**Dry-run** (preview without applying):
```bash
./install.sh --namespace qse-pod --openshift --dry-run
```

### Step 5 — Deploy manually (alternative)

If you prefer to apply manifests individually:

```bash
kubectl create namespace qse-pod

kubectl apply -f k8s/serviceaccount.yaml -n qse-pod
kubectl apply -f k8s/secret.yaml         -n qse-pod
kubectl apply -f k8s/configmap.yaml      -n qse-pod
kubectl apply -f k8s/pvc.yaml            -n qse-pod
kubectl apply -f k8s/cronjob.yaml        -n qse-pod

# OpenShift only (requires cluster-admin):
oc apply -f k8s/scc.yaml
```

### Adjusting the scan schedule

Edit the `spec.schedule` field in `k8s/cronjob.yaml`. Examples:

| Schedule | Cron expression |
|---|---|
| Every hour | `"0 * * * *"` |
| Every night at 02:00 | `"0 2 * * *"` |
| Every 30 minutes | `"*/30 * * * *"` |
| Every Monday 06:00 | `"0 6 * * 1"` |

### Trigger a manual scan

```bash
kubectl create job --from=cronjob/qse-pod-scan manual-scan-$(date +%s) -n qse-pod
```

---

## Monitoring and Troubleshooting

### Check CronJob status

```bash
kubectl get cronjob qse-pod-scan -n qse-pod
kubectl get jobs -n qse-pod -l app=qse-pod
```

### View live pod logs

```bash
# Most recent job pod
kubectl logs -n qse-pod -l app=qse-pod --tail=100 -f
```

### Inspect a specific completed job

```bash
# List pods for all jobs
kubectl get pods -n qse-pod -l app=qse-pod

# Tail a specific pod
kubectl logs -n qse-pod <pod-name> --tail=200
```

### Check last processed commit SHA

```bash
# From the PVC (exec into a debug pod):
kubectl run debug --rm -it --image=busybox \
  --overrides='{"spec":{"volumes":[{"name":"r","persistentVolumeClaim":{"claimName":"qse-pod-results"}}],"containers":[{"name":"debug","image":"busybox","command":["sh"],"volumeMounts":[{"name":"r","mountPath":"/results"}]}]}}' \
  -n qse-pod -- cat /results/last_commit

# From the ConfigMap (if patching is enabled):
kubectl get configmap qse-pod-config -n qse-pod -o jsonpath='{.data.last_commit_sha}'
```

### Reset to force a re-scan

```bash
# Clear the stored SHA to trigger a full re-scan on next run
kubectl run reset --rm -it --image=busybox \
  --overrides='{"spec":{"volumes":[{"name":"r","persistentVolumeClaim":{"claimName":"qse-pod-results"}}],"containers":[{"name":"reset","image":"busybox","command":["sh","-c","rm -f /results/last_commit"],"volumeMounts":[{"name":"r","mountPath":"/results"}]}]}}' \
  -n qse-pod
```

### Common issues

| Symptom | Likely cause | Fix |
|---|---|---|
| Pod exits 0 with "No new commits" | Expected behaviour — SHA unchanged | Trigger manually or reset SHA |
| `GCM_BEARER_TOKEN is not set` error | `GCM_UPLOAD_ENABLED=true` but the Secret key is missing | Uncomment/add `GCM_BEARER_TOKEN` in `k8s/secret.yaml` and re-apply, or set `GCM_UPLOAD_ENABLED: "false"` |
| Git clone fails with 128 | Invalid `GIT_TOKEN` or private repo | Check `GIT_TOKEN` in Secret |
| `QSE CLI not found` | Wrong `QSE_HOME` or bad image | Verify image build with `--secret id=QSE_TOKEN` |
| OpenShift: `unable to validate against SCC` | SCC not applied | Run `oc apply -f k8s/scc.yaml` as cluster-admin |
| PVC stays Pending | No matching StorageClass | Set `storageClassName` in `k8s/pvc.yaml` |

---

## QSE Flag Reference and Rationale

The QSE CLI (`cli.sh`) supports these flags (from `qse_flags.example`):

| Flag | Value used | Language(s) | Rationale |
|---|---|---|---|
| `-i` | `$WORKSPACE_DIR` | All | Input path: root of the cloned repository |
| `-l` | Auto-detected extensions | All | Comma-separated list e.g. `.java,.go,.py` — scoped to detected languages to avoid false positives |
| `-o` | `$QSE_OUTPUT_DIR` | All | Output directory on the PVC for persistent result storage |
| `-app` | `$APP_NAME` | All | Application name label in GCM; aids result correlation |
| `-app_ver` | `$APP_VERSION` or short commit SHA | All | Version label; ties scan results to a specific code revision |
| `-log` | *(flag only)* | All | Enables detailed log output; essential for troubleshooting in a containerised environment where logs are the only diagnostic channel |
| `-ef` | `$EXCLUDE_PATHS` | All | Excludes test directories, vendor code, and generated files from the scan to reduce noise |
| `-da` | *(flag only)* | Java, Python | Enables Usage Analysis: traces how cryptographic APIs are called through the call graph. Required for Python; for Java only applied when compiled class files are present |
| `-py_module_path` | `$PY_MODULE_PATH` | Python only | Path to externally installed Python modules (Option 2). Omitted when `PY_MODULE_PATH` is empty — QSE then resolves imports from the pip-installed venv created during Step 3 |
| `-cf` | `target/classes;target/dependency` or `build/classes;build/libs` | Java only | Required for Java advanced scan: points QSE to compiled class files and dependency JARs so it can perform bytecode-level analysis, which is more accurate than source-only scanning |
| `-em` | `true` | Dart only | Enables exact package name matching for Dart, reducing false positives from partial name matches in pub packages |

### Flags intentionally not used

| Flag | Reason omitted |
|---|---|
| `-ccdir` | Only needed for Dart class-catalog overrides; the default resource path is sufficient |
| `-nmo` | Name-matching-only mode reduces scan depth; not appropriate for a security scan |
| `-pf` | Path filter is repo-specific; `EXCLUDE_PATHS` via `-ef` covers the common cases |
| `-sf` | Source filter is repo-specific; not set globally to avoid skipping relevant code |
| `-config` | All configuration is injected via environment variables; a config file would duplicate this |

---

## GCM API Reference

When `GCM_UPLOAD_ENABLED=true`, `scan.sh` uploads findings to the GCM REST API using the following endpoints and conventions. Upload is **disabled by default**.

### Endpoints

| Findings file | HTTP method | Endpoint |
|---|---|---|
| `quantum_safe_api_discovery_findings.json` | `POST` | `{GCM_SERVER_URL}/ibm/pv/api/v1/upload-qse-findings/discovery?repositoryUrl=<encoded-repo-url>` |
| `quantum_safe_cryptography_analysis_findings_*.json` | `POST` | `{GCM_SERVER_URL}/ibm/pv/api/v1/upload-qse-findings/analytics?repositoryUrl=<encoded-repo-url>` |

The scanned repository URL is URL-encoded and passed as the `repositoryUrl` query parameter. Both files may be uploaded in the same run if both are present in the output directory.

### Authentication headers

```
Authorization: Bearer <GCM_BEARER_TOKEN>
token_type: api_key
```

`GCM_BEARER_TOKEN` is injected from the `qse-pod-secrets` Kubernetes Secret and is never logged.

### Request format

```
Content-Type: multipart/form-data
file=@<findings-file>;type=application/json
```

### Example curl commands

```bash
# Upload discovery findings
curl -X POST \
  '{GCM_SERVER_URL}/ibm/pv/api/v1/upload-qse-findings/discovery?repositoryUrl=https%3A%2F%2Fgithub.com%2Forg%2Frepo' \
  -H 'accept: application/json' \
  -H 'Authorization: Bearer <GCM_BEARER_TOKEN>' \
  -H 'token_type: api_key' \
  -H 'Content-Type: multipart/form-data' \
  -F 'file=@quantum_safe_api_discovery_findings.json;type=application/json'

# Upload analytics findings
curl -X POST \
  '{GCM_SERVER_URL}/ibm/pv/api/v1/upload-qse-findings/analytics?repositoryUrl=https%3A%2F%2Fgithub.com%2Forg%2Frepo' \
  -H 'accept: application/json' \
  -H 'Authorization: Bearer <GCM_BEARER_TOKEN>' \
  -H 'token_type: api_key' \
  -H 'Content-Type: multipart/form-data' \
  -F 'file=@quantum_safe_cryptography_analysis_findings_java.json;type=application/json'
```

### Retry behaviour

Transient server errors (HTTP 5xx) and curl errors are retried up to **3 times** with exponential backoff (5 s → 10 s → 20 s). Client errors (HTTP 4xx) fail immediately without retry.

---

## Security Design

- **No secrets hardcoded**: all credentials are injected via Kubernetes Secrets as environment variables.
- **`env.example`** is the only file with credential fields; `.env` (with real values) is gitignored.
- **GCM upload is opt-in**: `GCM_UPLOAD_ENABLED` defaults to `false`, so no scan data leaves the cluster and no GCM credential is required unless you enable it.
- **Bearer token never logged**: the `GCM_BEARER_TOKEN` variable is only used inside the `curl -H` argument and is never echoed or printed.
- **Workspace cleanup on any exit**: a `trap EXIT INT TERM` deletes the cloned repository regardless of whether the scan succeeds or fails.
- **Non-root container**: the image runs as UID 1001, with all directories group-writable for GID 0 (OpenShift's arbitrary UID pattern).
- **QSE token is build-time secret mount only**: the `QSE_TOKEN` used to clone the QSE CLI is mounted as a build secret (`--mount=type=secret,id=QSE_TOKEN`) in the builder stage, is never saved in layer history or image metadata, and is absent from the final runtime image layer.
- **Minimal RBAC**: the `ServiceAccount` is granted `get` and `patch` on its own `ConfigMap` only — no other permissions.
- **Image secrets**: use `imagePullSecrets` in `k8s/cronjob.yaml` if pulling from a private registry.

## Disclaimer
- Created by Erwin Friethoff, Security Architect at IBM using IBM Bob, our SDLC buddy. 
- This is 100% free and open source and not in any way endorsed or supported by IBM. All done on personal title. 
- If you have any questions, please reach out to me on Slack or LinkedIn. I’m happy to help.
- 100% free and open source. No warranty. 
- GitHub Issues: Report bugs or request features
