#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 00-run-all.sh  [--reuse-existing]
#
# Orchestrator that runs the setup phases in the correct order and stops
# on the first failure. Before touching anything on the JFrog side it:
#
#   1. Verifies every required tool is installed (preflight).
#   2. Runs the collision check against the target instance — if any
#      resource under the current POC_APP_NAME prefix already exists, the
#      pipeline stops and prints the three resolution options (change
#      prefix / teardown / --reuse-existing).
#
# Every child script is idempotent, so re-running the orchestrator after
# fixing a mid-pipeline error is safe.
# -----------------------------------------------------------------------------
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

REUSE_EXISTING=0
for arg in "$@"; do
  case "$arg" in
    --reuse-existing|--reuse) REUSE_EXISTING=1 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$here/.env" ]]; then
  echo "Creating setup/.env from template — please edit it before continuing."
  cp "$here/.env.example" "$here/.env"
  ${EDITOR:-vi} "$here/.env"
fi

# shellcheck disable=SC1091
source "$here/lib/common.sh"

# Preflight everything the entire pipeline can possibly need. Child scripts
# repeat their own subset — running twice is cheap and produces a clearer
# error surface if someone runs a child script standalone later.
preflight jf gh docker jq openssl curl

load_env

# ---- Collision check ---------------------------------------------------------
# This step reads-only. Bails out with resolution guidance if any resource
# already exists, unless --reuse-existing was passed.
if (( REUSE_EXISTING == 1 )); then
  "$here/00-check-collisions.sh" --reuse-existing
else
  "$here/00-check-collisions.sh"
fi

"$here/01-setup-curation.sh"
"$here/02-setup-users.sh"
"$here/03-setup-apptrust.sh"
"$here/03a-setup-signing-key.sh"

if [[ -n "${POC_GITHUB_REPO:-}" ]]; then
  "$here/04-setup-oidc.sh" "$POC_GITHUB_REPO"
else
  warn "POC_GITHUB_REPO not set in .env — skipping OIDC setup."
  warn "Run ./04-setup-oidc.sh <owner/repo> manually when ready."
fi

ok "All setup phases complete."
