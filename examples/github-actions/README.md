# Configure the QSE GitHub Actions workflow from a file

`setup-github-config.sh` sets all **GitHub Actions secrets and variables** used by [`.github/workflows/qse-scan.yml`](.github/workflows/qse-scan.yml) in one go, reading them from a local `KEY=VALUE` file. It replaces clicking through **Settings → Secrets and variables → Actions** by hand.

Use it in the repository that **uses** the workflow (the one you scan), not in `qse_pod`.

## Contents

| File | Purpose |
|---|---|
| [`setup-github-config.sh`](setup-github-config.sh) | The setup script |
| [`qse-github.env.example`](qse-github.env.example) | Template for the input file |
| [`.github/workflows/qse-scan.yml`](.github/workflows/qse-scan.yml) | The workflow these settings are for |

## Prerequisites

| Requirement | Notes |
|---|---|
| [GitHub CLI `gh`](https://cli.github.com/) | Logged in: `gh auth login`. The account needs **admin** (or equivalent) rights to manage Actions secrets and variables on the target repository. Fine-grained tokens need *Secrets* and *Variables* read/write permission |
| `bash` 3.2+ | Works on macOS and Linux (bash and zsh hosts) |
| `git` | Optional; used to keep the input file out of commits |

## Quick start

```bash
# 1. In the repository that uses the workflow
cp /path/to/qse_pod/examples/github-actions/setup-github-config.sh .
cp /path/to/qse_pod/examples/github-actions/qse-github.env.example .qse-github.env
chmod 600 .qse-github.env

# 2. Edit .qse-github.env: at minimum set QSE_TOKEN
$EDITOR .qse-github.env

# 3. Preview, then apply
./setup-github-config.sh --dry-run
./setup-github-config.sh
```

The script detects the repository from the current directory. To target another one: `./setup-github-config.sh --repo OWNER/REPO`.

## Input file format

Default path `./.qse-github.env` (override with `--env-file` or `QSE_CONFIG_FILE`).

```
# comment lines start with '#'
QSE_TOKEN=github_pat_xxx                 # trailing " # comment" is ignored # HashiCorpIgnore
EXCLUDE_PATHS="src/test,vendor"          # quotes are optional and removed
GCM_BEARER_TOKEN='abc#123'               # quote a value to keep a " #" in it
QSE_CLI_REF=                             # empty value = skipped
```

- The file is **parsed, never executed** (no `source`), so it cannot run code.
- Empty values are skipped, so you can keep every key in the file and fill in only what you need.
- Keys that the workflow does not use are skipped with a warning.
- Values that still look like template placeholders (`your-...`, `REPLACE_WITH...`, `<...>`) abort the run.

### Keys and where they are stored

| Key | Stored as | Required | Notes |
|---|---|---|---|
| `QSE_TOKEN` | **Secret** | **Yes** | PAT with read access to the private repo that holds `cli.sh` |
| `GCM_BEARER_TOKEN` | **Secret** | If GCM upload is on | GCM API bearer token |
| `GCM_UPLOAD_ENABLED` | Variable | No | `true`/`false` (case-insensitive, stored lower-case). Default is off |
| `GCM_SERVER_URL` | Variable | If GCM upload is on | Must start with `https://` |
| `QSE_REPO_URL` | Variable | No | Must start with `https://` |
| `QSE_CLI_SUBDIR` | Variable | No | Directory containing `cli.sh` |
| `QSE_CLI_REF` | Variable | No | Branch or tag of the CLI repo |
| `QSE_GIT_USERNAME` | Variable | No | Username paired with `QSE_TOKEN` |
| `QSE_APP_NAME` | Variable | No | `-app` label |
| `APP_VERSION` | Variable | No | `-app_ver` label |
| `EXCLUDE_PATHS` | Variable | No | `-ef` paths |
| `QSE_LANGUAGES` | Variable | No | Override language detection |
| `PY_MODULE_PATH` | Variable | No | `-py_module_path` |
| `QSE_JAVA_VERSION` | Variable | No | JDK version |

The meaning and defaults of every key are documented in the workflow header and in the main README section *GitHub Actions Workflow (Template)*.

> The workflow also accepts `GCM_UPLOAD_ENABLED` and `GCM_SERVER_URL` as **secrets**. This script always writes them as variables. Set them as secrets manually with `gh secret set` if you prefer.

## Usage

```
setup-github-config.sh [--repo OWNER/REPO] [--env-file FILE]
                       [--dry-run] [--remove] [--yes] [-h|--help]
```

| Option / variable | Description |
|---|---|
| `--repo OWNER/REPO`, `GITHUB_REPO` | Target repository. Default: the repository of the current directory |
| `--env-file FILE`, `QSE_CONFIG_FILE` | Input file. Default: `./.qse-github.env` |
| `--dry-run` | Validate and show what would change; nothing is sent to GitHub |
| `--remove` | **Rollback**: delete the secrets/variables named in the file from the repository |
| `--yes`, `-y`, `ALWAYS_ALLOW=true` | Skip the confirmation prompt |
| `LOG_LEVEL` | `DEBUG`, `INFO` (default), `WARN`, `ERROR` |

### What happens on a run

1. Checks `gh` is installed and authenticated and resolves the target repository.
2. Parses and validates the file (same rules as the workflow: `QSE_TOKEN` required, `https://` URLs, GCM settings consistent).
3. Shows a summary (repository, key names and types, never values) and asks for confirmation. Answer `always` to store an allow entry for that repository in `~/.config/qse-github-setup/always_allow`. The prompt is skipped with `--yes`, `ALWAYS_ALLOW=true`, or when stdin is not a terminal.
4. Sets each item with `gh secret set` / `gh variable set`.
5. Verifies that every name now exists in the repository (`gh secret list` / `gh variable list`).

### Examples

```bash
# GCM upload off (default): only the token is needed
printf 'QSE_TOKEN=github_pat_xxx\n' > .qse-github.env && ./setup-github-config.sh --yes # HashiCorpIgnore

# Turn GCM upload on later: add to the file, then re-run (existing items are overwritten)
#   GCM_UPLOAD_ENABLED=true
#   GCM_SERVER_URL=https://gcm.example.com
#   GCM_BEARER_TOKEN=...
./setup-github-config.sh

# Turn GCM upload off again, without re-entering the token
# (QSE_TOKEN may be omitted when it already exists in the repository)
printf 'GCM_UPLOAD_ENABLED=false\n' > gcm-off.env
./setup-github-config.sh --env-file gcm-off.env --yes

# Remove everything listed in the file from the repository
./setup-github-config.sh --remove
```

> **Note:** `QSE_TOKEN` must be in the file unless the secret already exists in the repository (checked via `gh`, not in `--dry-run`). With `--dry-run` a file without `QSE_TOKEN` is therefore reported as invalid.

## Security

- Secret values are piped to `gh` on **stdin**; they never appear on a command line, in `ps` output, or in the script's logs. `gh` encrypts secrets locally before sending them to GitHub.
- The input file holds secrets in clear text. The script warns if its mode is not `600`/`400` and, when it sits in a Git repository, **adds it to `.gitignore`** if it is not already ignored. Delete the file when you are done, or keep it in a password manager / vault and recreate it when needed.
- Use a **fine-grained** `QSE_TOKEN` limited to *Contents: Read-only* on the QSE CLI repository, with a short expiry, and rotate it by editing the file and re-running the script.
- GitHub never returns secret values, so overwritten secrets **cannot be backed up**. The rollback is `--remove` (delete) followed by a fresh run with the previous values.
- Review the summary before confirming: the target repository is shown first so you notice if you are about to configure the wrong one.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `GitHub CLI 'gh' not found` | Install from <https://cli.github.com/> |
| `gh is not authenticated` | `gh auth login` (or export `GH_TOKEN`) |
| `Could not detect the repository` | Run inside a clone of the target repository or pass `--repo OWNER/REPO` |
| `HTTP 403` / `Resource not accessible` when setting | The account lacks admin rights on the repository, or the token lacks Secrets/Variables permissions |
| `still has a placeholder value` | Replace the `your-...` / `REPLACE_WITH...` text in the file |
| `Validation failed - nothing was changed` | Fix the listed errors; no API call has been made yet |
| `Verification failed` | A set call was accepted but the name is not listed; re-run, and check organisation policies on Actions secrets |
| Org-level secret with the same name exists | The repository-level value set here takes precedence over the organisation's |
