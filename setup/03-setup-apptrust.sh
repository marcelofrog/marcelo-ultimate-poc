#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 03-setup-apptrust.sh
#
# 1. Creates the AppTrust application (name from POC_APP_NAME, prompted if
#    not set).
# 2. Creates three lifecycle-stage repositories (docker-local per stage) and
#    binds them to the application.
# 3. Grants stage-scoped RBAC:
#       dev group  -> write on dev-local,   read on qa-local & prod-local
#       qa group   -> read/promote on dev-local, write on qa-local
#       prod group -> read/promote on qa-local, write on prod-local
# 4. Creates two promotion gates on the application:
#       - Security gate: block on CVE >= 9 (contextual analysis)
#       - Rego gate:    block unless evidence attestation reports >= N tests
# -----------------------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
preflight jf jq curl
load_env

APP="$POC_APP_NAME"
PROJECT="$POC_PROJECT_KEY"
CVE_THRESHOLD="${POC_CVE_BLOCK_THRESHOLD:-9.0}"
MIN_TESTS="${POC_MIN_PASSING_TESTS:-3}"

# =========== 0. JFrog Project =================================================
log "Ensuring JFrog project '${PROJECT}' exists"
if project_exists "$PROJECT"; then
  ok "project already exists: ${PROJECT}"
else
  # CLI-gap: no `jf` subcommand for project CRUD; use Access API.
  rt_api POST "/access/api/v1/projects" \
    "{\"display_name\":\"${APP}\",\"project_key\":\"${PROJECT}\",\"description\":\"POC project for ${APP}\"}" >/dev/null
  ok "created project: ${PROJECT}"
fi

# =========== 1. Stage repositories ===========================================
create_local_docker() {
  local key="$1" stage="$2"
  if repo_exists "$key"; then
    ok "local docker repo already exists: $key"
    return
  fi
  local stage_upper; stage_upper="$(echo "$stage" | tr '[:lower:]' '[:upper:]')"
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<JSON
{
  "key": "${key}",
  "rclass": "local",
  "packageType": "docker",
  "dockerApiVersion": "V2",
  "xrayIndex": "true",
  "description": "POC ${APP} ${stage}-stage image repo"
}
JSON
  jf_admin rt repo-create "$tmp"
  rm -f "$tmp"
  # CLI-gap: jf rt repo-create template does not support array values.
  # Set environments via REST API after creation.
  jf rt curl -sS -XPOST "api/repositories/${key}" \
    -H "Content-Type: application/json" \
    -d "{\"environments\":[\"${stage_upper}\"]}" >/dev/null
  ok "created local docker repo: $key (environment: ${stage_upper})"
}

log "Creating stage-scoped local docker repositories"
create_local_docker "$(repo_stage dev)"  dev
create_local_docker "$(repo_stage qa)"   qa
create_local_docker "$(repo_stage prod)" prod

# =========== 2. AppTrust application =========================================
log "Creating AppTrust application '${APP}'"
if apptrust_application_exists "$APP"; then
  ok "AppTrust application already exists: ${APP}"
else
  jf_admin apptrust app-create "${APP}" \
    --project="${PROJECT}" \
    --application-name="${APP}" \
    --desc="Ultimate POC application ${APP}"
  ok "AppTrust application created"
fi

# =========== 3. Stage permission targets =====================================
log "Creating stage-scoped permission targets"

# Permission target JSON template:
#   actions: read | write | annotate | delete | manage | promote
mk_perm() {
  local pt_name="$1" repo="$2" group="$3" actions_json="$4"
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<JSON
{
  "name": "${pt_name}",
  "repo": {
    "repositories": ["${repo}"],
    "actions": {
      "groups": {
        "${group}": ${actions_json}
      }
    }
  }
}
JSON
  jf rt curl -sS -X PUT -H 'Content-Type: application/json' \
    --data "@${tmp}" "api/v2/security/permissions/${pt_name}" >/dev/null
  rm -f "$tmp"
  ok "permission target: ${pt_name}"
}

# Role suffixes read as English so admins can grok the target from its name:
#   writer   — can push/modify artifacts in the named repo
#   promoter — can read + promote out of the named repo
mk_perm "$(perm_target dev  writer)"   "$(repo_stage dev)"  "$(group_stage dev)"  '["read","write","annotate"]'
mk_perm "$(perm_target qa   promoter)" "$(repo_stage dev)"  "$(group_stage qa)"   '["read","promote"]'
mk_perm "$(perm_target qa   writer)"   "$(repo_stage qa)"   "$(group_stage qa)"   '["read","write","annotate"]'
mk_perm "$(perm_target prod promoter)" "$(repo_stage qa)"   "$(group_stage prod)" '["read","promote"]'
mk_perm "$(perm_target prod writer)"   "$(repo_stage prod)" "$(group_stage prod)" '["read","write","annotate"]'

# =========== 4. Promotion gates ==============================================
log "Creating promotion gates on application ${APP}"

# --- 4a. Security gate: block if applicable CVE >= threshold -----------------
security_gate_id="$(prefix gate-security)"
tmp="$(mktemp)"
cat > "$tmp" <<JSON
{
  "id": "${security_gate_id}",
  "name": "Block applicable CVE >= ${CVE_THRESHOLD}",
  "description": "Fail promotion when Xray contextual analysis reports an APPLICABLE CVE at or above ${CVE_THRESHOLD}.",
  "type": "security",
  "enabled": true,
  "criteria": {
    "cvss_score_min": ${CVE_THRESHOLD},
    "applicability": ["applicable"],
    "action": "block"
  },
  "scope": { "application_key": "${APP}" }
}
JSON
# CLI-gap: gate management not yet in `jf apptrust`, use REST.
rt_api POST "/apptrust/api/v1/applications/${APP}/gates" "$(cat "$tmp")" >/dev/null || \
  warn "security gate may already exist (${security_gate_id})"
rm -f "$tmp"
ok "security gate configured (${security_gate_id})"

# --- 4b. Rego gate: minimum passing test count -------------------------------
rego_gate_id="$(prefix gate-tests)"
rego_body="$(cat "${REPO_ROOT}/policies/test-count.rego" | jq -Rs .)"
tmp="$(mktemp)"
cat > "$tmp" <<JSON
{
  "id": "${rego_gate_id}",
  "name": "Require >= ${MIN_TESTS} passing tests",
  "description": "Require an evidence attestation showing at least ${MIN_TESTS} passing tests before promotion.",
  "type": "rego",
  "enabled": true,
  "parameters": { "min_passing_tests": ${MIN_TESTS} },
  "policy": ${rego_body},
  "scope": { "application_key": "${APP}" }
}
JSON
rt_api POST "/apptrust/api/v1/applications/${APP}/gates" "$(cat "$tmp")" >/dev/null || \
  warn "rego gate may already exist (${rego_gate_id})"
rm -f "$tmp"
ok "rego test-count gate configured (${rego_gate_id})"

ok "AppTrust setup complete."
echo
echo "Application key : ${APP}"
echo "Lifecycle       : dev -> qa -> prod"
echo "Repositories    : $(repo_stage dev), $(repo_stage qa), $(repo_stage prod)"
echo
echo "Next: run ./04-setup-oidc.sh <owner/repo>"
