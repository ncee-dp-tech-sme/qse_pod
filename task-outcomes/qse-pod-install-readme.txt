PROMPT: Do did not follow the coding-standards instruction I gave you. Please do next time and for now also create a script to install on openshift or k8s and a README.md with clear instructions and an explanation of the different steps so a user understands the flow of this.

DATE: 2026-08-21 04:01:56

== TASK OUTCOME ==

FILES CREATED / UPDATED
-----------------------
scripts/scan.sh     - Rewritten to comply with coding standards (see below)
env.example         - New: template for all configurable variables
install.sh          - New: one-command deploy script for Kubernetes and OpenShift
README.md           - New: full documentation with architecture, flow, deploy steps, flag reference

== CODING STANDARDS VIOLATIONS FIXED ==

1. FUNCTION COMMENT FORMAT
   All function comments now follow:  # Short description -- <timestamp>
   e.g.  # Fetch HEAD SHA of remote repo -- 2026-08-21 04:01:56

2. CHANGE LOG AT TOP OF FILE
   scan.sh and install.sh now have a dated change log in the header block:
   #   2026-08-21 04:01:56 - Initial creation: ...

3. .ENV LOADING
   scan.sh now loads a .env file at startup (if present) before any variable
   is referenced. In-cluster K8s env vars override .env values naturally.

4. ENV.EXAMPLE FILE
   env.example created with all variables that a user can provide at runtime.
   All secret-like values are marked # HashiCorpIgnore inline.

5. CONFIRMATION PROMPT BEFORE EXECUTION
   scan.sh now prints a full summary of what actions will be taken and warns
   about the repo deletion before asking for confirmation.
   - Responds to [y/N/always]
   - "always" stores .always_allow file so future runs skip the prompt
   - Automatically skipped in non-interactive (CronJob) environments
   - ALWAYS_ALLOW=true in .env also skips the prompt

6. INSTALL SCRIPT (install.sh)
   - Prints a summary of all actions before asking confirmation
   - Supports --dry-run, --openshift, --namespace, --kubeconfig, --always-allow
   - Runs preflight checks (binary presence, cluster reachability, placeholder detection)
   - Applies manifests in dependency order
   - Reports deployed resources after install
   - Works with both kubectl and oc

== FILE STRUCTURE ==

qse_pod/
├── Dockerfile
├── Containerfile
├── install.sh          ← NEW
├── env.example         ← NEW
├── README.md           ← NEW
├── scripts/
│   └── scan.sh         ← UPDATED (coding standards)
└── k8s/
    ├── secret.yaml
    ├── configmap.yaml
    ├── pvc.yaml
    ├── serviceaccount.yaml
    ├── cronjob.yaml
    └── scc.yaml
