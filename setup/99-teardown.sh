#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 99-teardown.sh   [--dry-run] [--yes] [--purge-builds] [--purge-local-keys]
#                  [--purge-github-secret]
#
# Removes every JFrog Artifactory / Access / AppTrust / Evidence / Curation
# object this POC created under the current POC_APP_NAME prefix. Deletion
# happens in dependency-safe order:
#
#     application versions & builds  →   AppTrust application (& gates)
#         →   permission targets   →   OIDC integrations
#         →   curation policies    →   repositories (local, then remote)
#         →   users                →   groups
#         →   evidence signing key
#
# Flags:
#   --dry-run              print the plan, don't call any DELETE.
#   --yes / -y             skip the interactive confirmation prompt.
#   --purge-builds         also delete build-info records under this app.
#   --purge-local-keys     also delete evidence/keys/ on disk.
#   --purge-github-secret  also delete POC_EVD_SIGNING_KEY + POC_EVD_KEY_ALIAS
#                          from the GitHub repo referenced in .env.
#
# The script tolerates missing objects — a resource that isn't present is
# reported as "absent", not "failed". At the end it prints a summary of
# deleted / absent / errored counts and exits non-zero if any DELETE
# failed unexpectedly.
# -----------------------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
preflight jf jq curl
load_env

DRY_RUN=0
ASSUME_YES=0
PURGE_BUILDS=0
PURGE_LOCAL_KEYS=0
PURGE_GH_SECRET=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)             DRY_RUN=1 ;;
    --yes|-y)              ASSUME_YES=1 ;;
    --purge-builds)        PURGE_BUILDS=1 ;;
    --purge-local-keys)    PURGE_LOCAL_KEYS=1 ;;
    --purge-github-secret) PURGE_GH_SECRET=1 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

APP="$POC_APP_NAME"

# ---------- confirmation -----------------------------------------------------
if (( DRY_RUN == 1 )); then
  log "DRY RUN — nothing will be deleted."
elif (( ASSUME_YES == 0 )); then
  echo
  warn "This will DELETE every JFrog object under prefix '${APP}' on ${JF_URL}."
  read -r -p "Type the app name (${APP}) to confirm: " confirm
  [[ "$confirm" == "$APP" ]] || die "confirmation did not match, aborting"
fi

deleted=0
absent=0
errored=0

# do_delete <kind> <name> <existence-probe> <delete-command...>
# The delete-command is passed via positional args after the probe name. If
# the probe returns "not present" the delete is skipped and counted as absent.
do_delete() {
  local kind="$1" name="$2" probe="$3"; shift 3
  local action_desc="$*"

  if ! $probe "$name" 2>/dev/null; then
    printf "  %-18s  %-45s  ${C_YELLOW}absent${C_RESET}\n" "$kind" "$name"
    absent=$((absent + 1))
    return
  fi

  if (( DRY_RUN == 1 )); then
    printf "  %-18s  %-45s  ${C_BLUE}would delete${C_RESET}\n" "$kind" "$name"
    deleted=$((deleted + 1))
    return
  fi

  if "$@" >/dev/null 2>&1; then
    printf "  %-18s  %-45s  ${C_GREEN}deleted${C_RESET}\n" "$kind" "$name"
    deleted=$((deleted + 1))
  else
    printf "  %-18s  %-45s  ${C_RED}ERROR${C_RESET}\n" "$kind" "$name"
    errored=$((errored + 1))
  fi
}

# Helper wrappers so `do_delete` calls stay readable ---------------------------
_del_repo()       { jf rt repo-delete "$1" --quiet; }
_del_user()       { jf rt curl -sS -X DELETE "api/security/users/$1" >/dev/null; }
_del_group()      { jf rt curl -sS -X DELETE "api/security/groups/$1" >/dev/null; }
_del_perm()       { jf rt curl -sS -X DELETE "api/v2/security/permissions/$1" >/dev/null; }
_del_oidc()       { rt_api DELETE "/access/api/v1/oidc/$1" >/dev/null; }
_del_curation()   {
  # CLI-gap: jf curation does not exist; delete via REST by resolving name→numeric id.
  local name="$1"
  local policy_id
  policy_id="$(jf api "/xray/api/v1/curation/policies?num_of_rows=1000" -X GET 2>/dev/null \
    | jq -r --arg n "$name" '.data[] | select(.name == $n) | .id' | head -1)"
  [[ -n "$policy_id" ]] || return 1
  jf api "/xray/api/v1/curation/policies/${policy_id}" -X DELETE 2>/dev/null
}
_del_gate()       { rt_api DELETE "/apptrust/api/v1/applications/${APP}/gates/$1" >/dev/null; }
_del_apptrust()   { rt_api DELETE "/apptrust/api/v1/applications/$1" >/dev/null; }
_del_evd_key()    { rt_api DELETE "/evidence/api/v1/keys/$1" >/dev/null; }

# ---------- 1. Application versions (must go before the app) ----------------
log "Removing AppTrust application versions"
if apptrust_application_exists "$APP"; then
  # List every version and delete it. If none exist, this loop no-ops.
  versions="$(rt_api GET "/apptrust/api/v1/applications/${APP}/versions" "" 2>/dev/null \
              | jq -r '.[]?.version // empty')"
  if [[ -n "$versions" ]]; then
    while read -r v; do
      [[ -z "$v" ]] && continue
      if (( DRY_RUN == 1 )); then
        printf "  %-18s  %-45s  ${C_BLUE}would delete${C_RESET}\n" "app version" "${APP}@${v}"
        deleted=$((deleted + 1))
      elif rt_api DELETE "/apptrust/api/v1/applications/${APP}/versions/${v}" >/dev/null 2>&1; then
        printf "  %-18s  %-45s  ${C_GREEN}deleted${C_RESET}\n" "app version" "${APP}@${v}"
        deleted=$((deleted + 1))
      else
        printf "  %-18s  %-45s  ${C_RED}ERROR${C_RESET}\n" "app version" "${APP}@${v}"
        errored=$((errored + 1))
      fi
    done <<< "$versions"
  else
    printf "  %-18s  %-45s  ${C_YELLOW}absent${C_RESET}\n" "app version" "(none)"
    absent=$((absent + 1))
  fi
else
  printf "  %-18s  %-45s  ${C_YELLOW}absent${C_RESET}\n" "app version" "(app doesn't exist)"
  absent=$((absent + 1))
fi

# ---------- 2. AppTrust gates ------------------------------------------------
log "Removing promotion gates"
do_delete "apptrust gate" "$(prefix gate-security)" "apptrust_gate_exists $APP" _del_gate "$(prefix gate-security)"
do_delete "apptrust gate" "$(prefix gate-tests)"    "apptrust_gate_exists $APP" _del_gate "$(prefix gate-tests)"

# ---------- 3. AppTrust application ------------------------------------------
log "Removing AppTrust application"
do_delete "apptrust app" "$APP" apptrust_application_exists _del_apptrust "$APP"

# ---------- 4. Permission targets --------------------------------------------
log "Removing permission targets"
for pt in \
    "$(perm_target dev  writer)" \
    "$(perm_target qa   promoter)" \
    "$(perm_target qa   writer)" \
    "$(perm_target prod promoter)" \
    "$(perm_target prod writer)"; do
  do_delete "permission" "$pt" permission_exists _del_perm "$pt"
done

# ---------- 5. OIDC integrations ---------------------------------------------
log "Removing OIDC integrations"
for i in "$(oidc_int dev)" "$(oidc_int qa)" "$(oidc_int prod)"; do
  do_delete "oidc integration" "$i" oidc_integration_exists _del_oidc "$i"
done

# ---------- 6. Curation policies ---------------------------------------------
log "Removing Curation blocking policies"
for p in "$(policy_id curation-malicious)" \
         "$(policy_id curation-no-license)" \
         "$(policy_id curation-immature)"; do
  do_delete "curation policy" "$p" curation_policy_exists _del_curation "$p"
done

# ---------- 6b. Curation condition -------------------------------------------
log "Removing custom curation condition"
_immature_cond_name="$(policy_id immature-7d)"
_immature_cond_id="$(curation_condition_id_by_name "$_immature_cond_name" 2>/dev/null || true)"
if [[ -z "$_immature_cond_id" ]]; then
  printf "  %-18s  %-45s  ${C_YELLOW}absent${C_RESET}\n" "curation cond" "$_immature_cond_name"
  absent=$((absent + 1))
elif (( DRY_RUN == 1 )); then
  printf "  %-18s  %-45s  ${C_BLUE}would delete${C_RESET}\n" "curation cond" "$_immature_cond_name"
  deleted=$((deleted + 1))
elif jf api "/xray/api/v1/curation/conditions/${_immature_cond_id}" -X DELETE 2>/dev/null; then
  printf "  %-18s  %-45s  ${C_GREEN}deleted${C_RESET}\n" "curation cond" "$_immature_cond_name"
  deleted=$((deleted + 1))
else
  printf "  %-18s  %-45s  ${C_RED}ERROR${C_RESET}\n" "curation cond" "$_immature_cond_name"
  errored=$((errored + 1))
fi

# ---------- 7. Repositories --------------------------------------------------
# Locals first (they reference remotes indirectly through virtuals/pipelines),
# then remotes.
log "Removing local stage repositories"
for r in "$(repo_stage dev)" "$(repo_stage qa)" "$(repo_stage prod)"; do
  do_delete "repo (local)" "$r" repo_exists _del_repo "$r"
done

log "Removing curated remote repositories"
for r in "$(repo_pypi)" "$(repo_npm)" "$(repo_docker)"; do
  do_delete "repo (remote)" "$r" repo_exists _del_repo "$r"
done

# ---------- 8. Users then groups (order matters — users reference groups) ---
log "Removing service users"
for u in "$(stage_user dev)" "$(stage_user qa)" "$(stage_user prod)"; do
  do_delete "user (svc)" "$u" user_exists _del_user "$u"
done

log "Removing groups"
for g in "$(group_stage dev)" "$(group_stage qa)" "$(group_stage prod)"; do
  do_delete "group" "$g" group_exists _del_group "$g"
done

# ---------- 9. Evidence signing key ------------------------------------------
log "Removing Evidence signing key"
do_delete "evidence key" "${APP}-evd-key" evidence_key_exists _del_evd_key "${APP}-evd-key"

# ---------- 10. Optional: build info -----------------------------------------
if (( PURGE_BUILDS == 1 )); then
  log "Purging build info under name '${APP}'"
  if (( DRY_RUN == 1 )); then
    printf "  %-18s  %-45s  ${C_BLUE}would purge${C_RESET}\n" "build info" "$APP"
  else
    jf rt build-delete "$APP" --quiet 2>/dev/null \
      && printf "  %-18s  %-45s  ${C_GREEN}purged${C_RESET}\n" "build info" "$APP" \
      || printf "  %-18s  %-45s  ${C_YELLOW}absent or already gone${C_RESET}\n" "build info" "$APP"
  fi
fi

# ---------- 11. Optional: local key material ---------------------------------
if (( PURGE_LOCAL_KEYS == 1 )); then
  log "Purging local key material"
  local_keys_dir="${REPO_ROOT}/evidence/keys"
  if [[ -d "$local_keys_dir" ]]; then
    if (( DRY_RUN == 1 )); then
      printf "  %-18s  %-45s  ${C_BLUE}would delete${C_RESET}\n" "local keys" "$local_keys_dir"
    else
      rm -rf "$local_keys_dir"
      printf "  %-18s  %-45s  ${C_GREEN}deleted${C_RESET}\n" "local keys" "$local_keys_dir"
    fi
  else
    printf "  %-18s  %-45s  ${C_YELLOW}absent${C_RESET}\n" "local keys" "$local_keys_dir"
  fi
fi

# ---------- 12. Optional: GitHub secret --------------------------------------
if (( PURGE_GH_SECRET == 1 )); then
  log "Purging GitHub secret + variable"
  : "${POC_GITHUB_REPO:?POC_GITHUB_REPO must be set in .env for --purge-github-secret}"
  if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    warn "gh CLI unavailable or not authenticated — skipping"
  else
    if (( DRY_RUN == 1 )); then
      printf "  %-18s  %-45s  ${C_BLUE}would delete${C_RESET}\n" "github secret" "POC_EVD_SIGNING_KEY"
      printf "  %-18s  %-45s  ${C_BLUE}would delete${C_RESET}\n" "github var"    "POC_EVD_KEY_ALIAS"
    else
      gh secret   delete POC_EVD_SIGNING_KEY --repo "$POC_GITHUB_REPO" 2>/dev/null \
        && printf "  %-18s  %-45s  ${C_GREEN}deleted${C_RESET}\n" "github secret" "POC_EVD_SIGNING_KEY" \
        || printf "  %-18s  %-45s  ${C_YELLOW}absent${C_RESET}\n" "github secret" "POC_EVD_SIGNING_KEY"
      gh variable delete POC_EVD_KEY_ALIAS   --repo "$POC_GITHUB_REPO" 2>/dev/null \
        && printf "  %-18s  %-45s  ${C_GREEN}deleted${C_RESET}\n" "github var" "POC_EVD_KEY_ALIAS" \
        || printf "  %-18s  %-45s  ${C_YELLOW}absent${C_RESET}\n" "github var" "POC_EVD_KEY_ALIAS"
    fi
  fi
fi

# ---------- summary ----------------------------------------------------------
echo
if (( DRY_RUN == 1 )); then
  log "Dry-run summary: ${deleted} would-delete, ${absent} absent, ${errored} errors"
  exit 0
fi

log "Summary: ${deleted} deleted, ${absent} absent, ${errored} errors"

if (( errored > 0 )); then
  die "Teardown finished with ${errored} error(s). Some resources may need manual cleanup."
fi

ok "Teardown complete."
if (( PURGE_LOCAL_KEYS == 0 )); then
  echo
  warn "Local key material at evidence/keys/ was NOT deleted."
  warn "Re-run with --purge-local-keys to remove it, or delete manually."
fi
if (( PURGE_GH_SECRET == 0 )); then
  warn "GitHub secret POC_EVD_SIGNING_KEY was NOT deleted."
  warn "Re-run with --purge-github-secret to remove it, or use: gh secret delete POC_EVD_SIGNING_KEY --repo <owner/repo>"
fi
