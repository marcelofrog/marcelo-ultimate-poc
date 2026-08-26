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
preflight jf jq curl gh
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
  "claims": {"repository": "${OWNER}/${REPO}", "environment": "${stage}"},
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

# ---------- GitHub side: environments + variables ----------------------------
log "Configuring GitHub repo ${OWNER}/${REPO}"

# Look up the caller's GitHub user ID for required-reviewer config on qa/prod.
REVIEWER_ID="$(gh api user --jq '.id' 2>/dev/null)" \
  || die "Cannot look up GitHub user ID — check gh auth status"
ok "GitHub user id: ${REVIEWER_ID}"

# Repo-level variables used by all workflow jobs (not environment-scoped).
log "Setting repo-level variables"
gh variable set JF_URL             --repo "${OWNER}/${REPO}" --body "${JF_URL}"
gh variable set JF_DOCKER_REGISTRY --repo "${OWNER}/${REPO}" --body "${POC_DOCKER_REGISTRY_HOST}"
gh variable set POC_APP_NAME       --repo "${OWNER}/${REPO}" --body "${APP}"
ok "repo variables: JF_URL, JF_DOCKER_REGISTRY, POC_APP_NAME"

# create_gh_env <stage> <oidc_provider_name> [require_review=true|false]
create_gh_env() {
  local stage="$1" oidc_provider="$2" require_review="${3:-false}"
  log "GitHub environment: ${stage}"

  # Create or update the environment.  review_policy is only set when needed
  # so dev doesn't get a spurious empty reviewers array.
  if [[ "$require_review" == "true" ]]; then
    gh api "repos/${OWNER}/${REPO}/environments/${stage}" \
      -X PUT \
      -H "Accept: application/vnd.github+json" \
      --field "reviewers[][type]=User" \
      --field "reviewers[][id]=${REVIEWER_ID}" \
      >/dev/null
  else
    gh api "repos/${OWNER}/${REPO}/environments/${stage}" \
      -X PUT \
      -H "Accept: application/vnd.github+json" \
      >/dev/null
  fi

  # Set the environment-scoped variable that tells workflows which OIDC
  # provider to request a token from.
  gh variable set JF_OIDC_PROVIDER \
    --repo "${OWNER}/${REPO}" \
    --env "${stage}" \
    --body "${oidc_provider}"

  if [[ "$require_review" == "true" ]]; then
    ok "environment '${stage}': JF_OIDC_PROVIDER=${oidc_provider} (required reviewer: ${REVIEWER_ID})"
  else
    ok "environment '${stage}': JF_OIDC_PROVIDER=${oidc_provider}"
  fi
}

create_gh_env "dev"  "$(oidc_int dev)"  false
create_gh_env "qa"   "$(oidc_int qa)"   true
create_gh_env "prod" "$(oidc_int prod)" true

ok "OIDC setup complete."

cat <<EOF

────────────────────────────────────────────────────────────────────────────
GitHub repo ${OWNER}/${REPO} is now configured:

  Environments created : dev, qa, prod
  qa + prod            : require reviewer approval before a workflow can
                         obtain an OIDC token for those stages
  Repo variables set   : JF_URL, JF_DOCKER_REGISTRY, POC_APP_NAME
  Env variable per env : JF_OIDC_PROVIDER

You do NOT need to set any GitHub secret — all authentication is OIDC.
────────────────────────────────────────────────────────────────────────────
EOF
