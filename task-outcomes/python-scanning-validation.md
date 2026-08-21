## Prompt
Python scanning has some instructions: Before scanning, ensure all Python dependencies are available (Option 1: install in project dir / Option 2: specify -py_module_path). Validate the scan.sh is configured correctly.

## Findings — gaps before fix

| # | Issue | File | Detail |
|---|-------|------|--------|
| 1 | `-da` flag never passed for Python | `scripts/scan.sh` | Only Java triggered `-da`; Python requires it unconditionally |
| 2 | `-py_module_path` not supported | `scripts/scan.sh` | No env var read, no CLI flag forwarded |
| 3 | Python deps not installed before scan | `scripts/scan.sh` | No `compile_python()` step existed |
| 4 | `venv` missing from default exclusions | `k8s/configmap.yaml` | Virtual-env dirs would have been scanned |
| 5 | `PY_MODULE_PATH` not documented/exposed | `k8s/configmap.yaml` | Env var had no ConfigMap entry |

## Changes made

### `scripts/scan.sh`
- **`detect_languages()`** — initialises `NEEDS_PYTHON_DEPS=false`; sets it to `true` when Python files/manifests are found (was already detected but flag was missing).
- **`compile_python()`** — new function (Option 1): creates an isolated venv at `<repo>/.qse-venv`, runs `pip install -r requirements.txt` and/or `pip install -e .` depending on what's present. Errors are non-fatal (warns and continues).
- **`run_qse_scan()`** — Python block added before Java block:
  - Always appends `-da` when `.py` is in detected languages.
  - Appends `-py_module_path "${PY_MODULE_PATH}"` when `PY_MODULE_PATH` env var is non-empty (Option 2).
- **`scan_repo()` Step 3** — `compile_python` wired into the pre-compile sequence.
- **Header** — `PY_MODULE_PATH` documented in env var table; changelog entry added.

### `k8s/configmap.yaml`
- `EXCLUDE_PATHS` — added `venv,.qse-venv` to default list.
- New key `PY_MODULE_PATH: ""` — empty by default (Option 1 path); set to a path to enable Option 2.

## Validation
- `bash -n scripts/scan.sh` → **Syntax OK**
- `shellcheck -S warning scripts/scan.sh` → 3 pre-existing warnings only (SC1090, SC2038, SC2034); **0 new warnings**
