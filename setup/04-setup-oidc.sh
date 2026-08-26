#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 04-setup-oidc.sh <github-org/repo>
#
# Creates THREE OIDC integrations in JFrog, one per lifecycle stage. Each is
# bound to a specific GitHub Environment, so a workflow that requests the
# `dev` environment can only receive tokens for the `<app>-dev-svc` user — GitHub
# itself refuses to mint an OIDC token for `qa` or `prod` to that job.
#
# This is the core RBAC boundary of the POC. Do not skip it.
# -----------------------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
preflight jf jq curl
load_env

REPO_ARG="${1:-${POC_GITHUB_REPO:-}}"
[[ -n "$REPO_ARG" ]] || die "usage: $0 <github-org/repo>   (or set POC_GITHUB_REPO in .env)"
[[ "$REPO_ARG" =~ ^[^/]+/[^/]+$ ]] || die "invalid <owner/repo>: $REPO_ARG"

OWNER="${REPO_ARG%%/*}"
REPO="${REPO_ARG##*/}"

APP="$POC_APP_NAME"
ISSUER="https://token.actions.githubusercontent.com"
AUDIENCE="jfrog-${APP}"

create_oidc() {
  local integration="$1" stage="$2" username="$3"
  log "OIDC integration: ${integration}  (stage=${stage} user=${username})"

  # CLI-gap: as of jf CLI 2.68 there is no first-class `jf` subcommand for
  # OIDC integration management. The setup relies on Access REST endpoints.
  # If a future CLI adds this, switch this block over.
  local tmp; tmp="$(mktemp)"

  # 1. Create integration (idempotent — 409 == already exists)
  cat > "$tmp" <<JSON
{
  "name": "${integration}",
  "issuer_url": "${ISSUER}",
  "provider_type": "generic-openid",
  "audience": "${AUDIENCE}",
  "description": "GitHub Actions ${stage} stage for POC ${APP}"
}
JSON
  local http
  http="$(rt_api_status POST "/access/api/v1/oidc" "$(cat "$tmp")")"
  case "$http" in
    201|409) ok "integration ${integration} present" ;;
    *)       warn "unexpected status $http creating integration ${integration}" ;;
  esac

  # 2. Create the single identity mapping that binds environment+repo to the user
  cat > "$tmp" <<JSON
{
  "name": "${integration}-map",
  "priority": 100,
  "claims_json": "{\"repository\": \"${OWNER}/${REPO}\", \"environment\": \"${stage}\"}",
  "token_spec": {
    "username": "${username}",
    "scope": "applied-permissions/groups:$(group_stage "$stage")",
    "expires_in": 3600
  }
}
JSON
  http="$(rt_api_status POST "/access/api/v1/oidc/${integration}/identity_mappings" "$(cat "$tmp")")"
  case "$http" in
    201|409) ok "identity mapping present for ${integration}" ;;
    *)       warn "unexpected status $http creating mapping for ${integration}" ;;
  esac
  rm -f "$tmp"
}

create_oidc "$(oidc_int dev)"  "dev"  "$(stage_user dev)"
create_oidc "$(oidc_int qa)"   "qa"   "$(stage_user qa)"
create_oidc "$(oidc_int prod)" "prod" "$(stage_user prod)"

# ---------- Print instructions for the GitHub side ----------------------------
cat <<EOF

────────────────────────────────────────────────────────────────────────────
Next, on GitHub (${OWNER}/${REPO}):

1. Go to Settings > Environments and create three environments:

     dev   qa   prod

   For **qa** and **prod** add "Required reviewers" (yourself) so promotion
   requires human approval.

2. In each environment, add a single Environment Variable:

     JF_OIDC_PROVIDER = <one of:>
        dev   -> $(oidc_int dev)
        qa    -> $(oidc_int qa)
        prod  -> $(oidc_int prod)

3. As a repo-level *variable* (not a secret) set:

     JF_URL              = ${JF_URL}
     JF_DOCKER_REGISTRY  = ${POC_DOCKER_REGISTRY_HOST:-<hostname of JFrog>}
     POC_APP_NAME        = ${APP}

You do NOT need to set any GitHub secret — all authentication is OIDC.
────────────────────────────────────────────────────────────────────────────
EOF

ok "OIDC setup complete."
