#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 00-check-collisions.sh  [--reuse-existing]
#
# Enumerates every JFrog object the setup pipeline (01 → 04) is about to
# create, probes the target instance for each, and prints a matrix of
# results. Runs BEFORE any mutation happens.
#
#   • Exit 0  -> nothing exists; the setup can proceed cleanly.
#   • Exit 2  -> collisions found; script prints them and stops so the user
#                can decide.  Pass --reuse-existing to accept collisions and
#                continue (individual scripts remain idempotent — they skip
#                objects that already exist).
#   • Exit 1  -> unexpected error (auth, connectivity).
#
# Nothing in this script writes to JFrog.
# -----------------------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
preflight jf jq curl
load_env

REUSE_EXISTING=0
for arg in "$@"; do
  case "$arg" in
    --reuse-existing|--reuse) REUSE_EXISTING=1 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

APP="$POC_APP_NAME"

# ---------- checklist --------------------------------------------------------
# Each row: <kind>|<name>|<probe function>
CHECKLIST=(
  # Repositories — remote (curated) + local (stage)
  "repo (remote)|$(repo_pypi)|repo_exists"
  "repo (remote)|$(repo_npm)|repo_exists"
  "repo (remote)|$(repo_docker)|repo_exists"
  "repo (local)|$(repo_stage dev)|repo_exists"
  "repo (local)|$(repo_stage qa)|repo_exists"
  "repo (local)|$(repo_stage prod)|repo_exists"

  # Groups
  "group|$(group_stage dev)|group_exists"
  "group|$(group_stage qa)|group_exists"
  "group|$(group_stage prod)|group_exists"

  # Service users
  "user (svc)|$(stage_user dev)|user_exists"
  "user (svc)|$(stage_user qa)|user_exists"
  "user (svc)|$(stage_user prod)|user_exists"

  # Permission targets
  "permission|$(perm_target dev  writer)|permission_exists"
  "permission|$(perm_target qa   promoter)|permission_exists"
  "permission|$(perm_target qa   writer)|permission_exists"
  "permission|$(perm_target prod promoter)|permission_exists"
  "permission|$(perm_target prod writer)|permission_exists"

  # AppTrust application + gates
  "apptrust app|${APP}|apptrust_application_exists"
  "apptrust gate|$(prefix gate-security)|apptrust_gate_exists ${APP}"
  "apptrust gate|$(prefix gate-tests)|apptrust_gate_exists ${APP}"

  # Curation policies
  "curation policy|$(policy_id curation-malicious)|curation_policy_exists"
  "curation policy|$(policy_id curation-no-license)|curation_policy_exists"
  "curation policy|$(policy_id curation-immature)|curation_policy_exists"

  # OIDC integrations
  "oidc integration|$(oidc_int dev)|oidc_integration_exists"
  "oidc integration|$(oidc_int qa)|oidc_integration_exists"
  "oidc integration|$(oidc_int prod)|oidc_integration_exists"

  # Evidence signing key
  "evidence key|${APP}-evd-key|evidence_key_exists"
)

# ---------- probe ------------------------------------------------------------
log "Probing ${#CHECKLIST[@]} objects on ${JF_URL}"
echo

collisions=()
missing=()
printf "  %-18s  %-45s  %s\n" "KIND" "NAME" "STATUS"
printf "  %-18s  %-45s  %s\n" "----" "----" "------"

for row in "${CHECKLIST[@]}"; do
  IFS='|' read -r kind name probe <<< "$row"
  # probe may include trailing args (e.g. app key for gate probe)
  if $probe "$name" 2>/dev/null; then
    printf "  %-18s  %-45s  ${C_YELLOW}EXISTS${C_RESET}\n" "$kind" "$name"
    collisions+=("${kind}::${name}")
  else
    printf "  %-18s  %-45s  ${C_GREEN}free${C_RESET}\n" "$kind" "$name"
    missing+=("${kind}::${name}")
  fi
done

echo
log "Result: ${#missing[@]} free / ${#collisions[@]} existing"

# ---------- verdict ----------------------------------------------------------
if (( ${#collisions[@]} == 0 )); then
  ok "No collisions. Safe to run the setup pipeline."
  exit 0
fi

if (( REUSE_EXISTING == 1 )); then
  warn "Collisions accepted via --reuse-existing. Individual setup scripts will skip existing objects."
  exit 0
fi

# Non-empty collisions and no --reuse-existing → block and guide.
cat >&2 <<EOF

${C_RED}✗  ${#collisions[@]} object(s) already exist under prefix '${APP}'.${C_RESET}

You have three ways forward:

  ${C_BOLD}1. Pick a different prefix (recommended for shared tenants)${C_RESET}
     Edit setup/.env and change POC_APP_NAME to something unique, then
     re-run this check.

  ${C_BOLD}2. Wipe the existing objects${C_RESET}
     Run:  ./setup/99-teardown.sh
     (You will be asked to type the app name to confirm.)

  ${C_BOLD}3. Accept and reuse${C_RESET}
     Re-run with:  ./setup/00-check-collisions.sh --reuse-existing
     Every child script is idempotent, so existing objects will be
     detected and skipped rather than overwritten.

     Use this option when a previous partial run left objects behind, or
     when you deliberately want to layer this POC on top of pre-existing
     tenant resources.

EOF
exit 2
