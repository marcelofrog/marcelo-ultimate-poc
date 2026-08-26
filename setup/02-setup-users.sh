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

ok "Users setup complete."
echo
echo "Next: run ./03-setup-apptrust.sh"
