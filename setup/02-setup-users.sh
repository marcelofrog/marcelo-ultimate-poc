#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 02-setup-users.sh
#
# Creates three lifecycle-stage users (dev, qa, prod) and their groups.
#
# NO PASSWORD IS EVER READ FROM THE ENVIRONMENT OR PROMPTED FOR.
# The JFrog User API requires a password field at create time, so the script
# generates a random 32-byte value in memory, hands it to the API, then
# throws it away. Internal password login is disabled on the user record
# in the same call, so the value is effectively write-only — nothing ever
# authenticates with it, including this script.
#
# All subsequent authentication for these users happens via the OIDC
# identity mappings created in 04-setup-oidc.sh.
# -----------------------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
preflight jf jq curl openssl
load_env

APP="$POC_APP_NAME"

# Ephemeral password generator. Value never leaves this function.
ephemeral_password() {
  # 24 random bytes, base64 -> ~32 URL-safe chars. Meets JFrog complexity.
  openssl rand -base64 24 | tr -d '\n=' | tr '/+' '_-'
}

create_group() {
  local g="$1"
  if jf rt curl -sS "api/security/groups/${g}" 2>/dev/null | jq -e '.name' >/dev/null; then
    ok "group already exists: $g"
    return
  fi
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<JSON
{ "name": "${g}", "description": "POC ${APP} stage group ${g}", "autoJoin": false, "adminPrivileges": false, "realm": "internal" }
JSON
  jf rt curl -sS -X PUT -H 'Content-Type: application/json' --data "@${tmp}" "api/security/groups/${g}" >/dev/null
  rm -f "$tmp"
  ok "created group: $g"
}

# create_user creates a user with a throwaway password and immediately
# disables internal password auth. The account is unusable for password
# login from the moment it is created.
create_user() {
  local username="$1" group="$2"
  if user_exists "$username"; then
    ok "user already exists: $username"
    return
  fi
  local password; password="$(ephemeral_password)"
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<JSON
{
  "name": "${username}",
  "email": "${username}@example.com",
  "password": "${password}",
  "groups": ["${group}"],
  "disableUIAccess": true,
  "internalPasswordDisabled": true,
  "profileUpdatable": false
}
JSON
  jf rt curl -sS -X PUT -H 'Content-Type: application/json' --data "@${tmp}" "api/security/users/${username}" >/dev/null
  # Zero out the password variable in shell memory before it goes out of scope.
  password=""
  rm -f "$tmp"
  ok "created user: $username (group: $group, password-login disabled)"
}

log "Creating stage groups"
create_group "$(group_stage dev)"
create_group "$(group_stage qa)"
create_group "$(group_stage prod)"

log "Creating stage service users (OIDC-only, internal password auth disabled)"
create_user "$(stage_user dev)"  "$(group_stage dev)"
create_user "$(stage_user qa)"   "$(group_stage qa)"
create_user "$(stage_user prod)" "$(group_stage prod)"

# ---------- Permission targets ---------------------------------------------------
# Each target is idempotent (PUT is create-or-replace).
# Writers get read+annotate+write on curated remotes AND their stage local.
# Promoters get read on the source stage local and write on the target.
create_perm_target() {
  local name="$1" group="$2" repos_json="$3"
  if permission_exists "$name"; then
    ok "permission target already exists: $name — updating"
  fi
  jf rt curl -sS -X PUT -H "Content-Type: application/json" \
    --data "{
      \"name\": \"${name}\",
      \"repo\": {
        \"include-patterns\": [\"**\"],
        \"exclude-patterns\": [],
        \"repositories\": ${repos_json},
        \"actions\": { \"groups\": { \"${group}\": [\"read\",\"annotate\",\"write\"] } }
      }
    }" "api/v2/security/permissions/${name}" >/dev/null
  ok "permission target: $name"
}

REMOTES="[\"$(repo_pypi)\",\"$(repo_npm)\",\"$(repo_docker)\"]"
DEV_REPOS="[\"$(repo_stage dev)\",\"$(repo_pypi)\",\"$(repo_npm)\",\"$(repo_docker)\"]"
QA_REPOS="[\"$(repo_stage qa)\",\"$(repo_pypi)\",\"$(repo_npm)\",\"$(repo_docker)\"]"
PROD_REPOS="[\"$(repo_stage prod)\",\"$(repo_pypi)\",\"$(repo_npm)\",\"$(repo_docker)\"]"

log "Creating permission targets"
create_perm_target "$(perm_target dev  writer)"   "$(group_stage dev)"  "$DEV_REPOS"
create_perm_target "$(perm_target qa   writer)"   "$(group_stage qa)"   "$QA_REPOS"
create_perm_target "$(perm_target prod writer)"   "$(group_stage prod)" "$PROD_REPOS"
# Promoters need read on source stage and write on target stage
create_perm_target "$(perm_target qa   promoter)" "$(group_stage qa)"   "[\"$(repo_stage dev)\",\"$(repo_stage qa)\"]"
create_perm_target "$(perm_target prod promoter)" "$(group_stage prod)" "[\"$(repo_stage qa)\",\"$(repo_stage prod)\"]"

ok "Users setup complete."
echo
echo "Next: run ./03-setup-apptrust.sh"
