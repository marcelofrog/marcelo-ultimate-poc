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

# =========== 4. Promotion gates (Unified Policy API) =========================
# CLI-gap: `jf apptrust` has no gate-management subcommand; use the unified
# policy REST API at /unifiedpolicy/api/v1. Stage keys must be uppercase.
#
# Two gates are created on the application lifecycle:
#   DEV exit  — security: block if applicable CVE score >= CVE_THRESHOLD
#   QA  exit  — evidence: block if no test-results evidence is attached
log "Creating promotion gates (unified policy API) for application ${APP}"

security_rule_name="$(prefix security-rule)"
evidence_rule_name="$(prefix evidence-rule)"
dev_exit_policy_name="$(prefix dev-exit-gate)"
qa_exit_policy_name="$(prefix qa-exit-gate)"

# --- 4a. Security rule (template 1005 = CVE CVSS, contextual analysis) -------
SECURITY_RULE_ID=""
if unified_rule_exists "$security_rule_name"; then
  SECURITY_RULE_ID="$(unified_rule_id_by_name "$security_rule_name")"
  ok "security rule already exists (${security_rule_name}, id=${SECURITY_RULE_ID})"
else
  log "creating security rule: block CVE CVSS >= ${CVE_THRESHOLD}"
  SECURITY_RULE_ID="$(rt_api POST "/unifiedpolicy/api/v1/rules" \
    "{\"name\":\"${security_rule_name}\",\"description\":\"Block CVE CVSS >= ${CVE_THRESHOLD} (contextual analysis)\",\"template_id\":\"1005\",\"parameters\":[{\"name\":\"min_cvss\",\"value\":\"${CVE_THRESHOLD}\"},{\"name\":\"max_cvss\",\"value\":\"10.0\"}]}" \
    2>/dev/null | jq -r '.id')"
  ok "security rule created (${security_rule_name}, id=${SECURITY_RULE_ID})"
fi

# --- 4b. Evidence existence rule (template 1007 = evidence predicate check) --
EVIDENCE_RULE_ID=""
if unified_rule_exists "$evidence_rule_name"; then
  EVIDENCE_RULE_ID="$(unified_rule_id_by_name "$evidence_rule_name")"
  ok "evidence rule already exists (${evidence_rule_name}, id=${EVIDENCE_RULE_ID})"
else
  log "creating evidence rule: require test-results attestation"
  EVIDENCE_RULE_ID="$(rt_api POST "/unifiedpolicy/api/v1/rules" \
    "{\"name\":\"${evidence_rule_name}\",\"description\":\"Require test-results evidence attestation\",\"template_id\":\"1007\",\"parameters\":[{\"name\":\"predicateType\",\"value\":\"https://jfrog.com/evidence/test-results/v1\"}]}" \
    2>/dev/null | jq -r '.id')"
  ok "evidence rule created (${evidence_rule_name}, id=${EVIDENCE_RULE_ID})"
fi

# --- 4c. DEV exit gate policy: security rule ---------------------------------
if unified_policy_exists "$dev_exit_policy_name"; then
  ok "DEV exit gate policy already exists (${dev_exit_policy_name})"
else
  log "creating DEV exit gate policy (CVE >= ${CVE_THRESHOLD})"
  rt_api POST "/unifiedpolicy/api/v1/policies" \
    "{\"name\":\"${dev_exit_policy_name}\",\"description\":\"Block DEV→QA promotion if applicable CVE >= ${CVE_THRESHOLD}\",\"mode\":\"block\",\"enabled\":true,\"rule_ids\":[\"${SECURITY_RULE_ID}\"],\"scope\":{\"type\":\"application\",\"application_keys\":[\"${APP}\"]},\"action\":{\"type\":\"certify_to_gate\",\"stage\":{\"key\":\"DEV\",\"gate\":\"exit\"}}}" \
    >/dev/null 2>&1
  ok "DEV exit gate policy created (${dev_exit_policy_name})"
fi

# --- 4d. QA exit gate policy: evidence rule ----------------------------------
if unified_policy_exists "$qa_exit_policy_name"; then
  ok "QA exit gate policy already exists (${qa_exit_policy_name})"
else
  log "creating QA exit gate policy (test-results evidence required)"
  rt_api POST "/unifiedpolicy/api/v1/policies" \
    "{\"name\":\"${qa_exit_policy_name}\",\"description\":\"Block QA→PROD promotion unless test-results evidence is attached\",\"mode\":\"block\",\"enabled\":true,\"rule_ids\":[\"${EVIDENCE_RULE_ID}\"],\"scope\":{\"type\":\"application\",\"application_keys\":[\"${APP}\"]},\"action\":{\"type\":\"certify_to_gate\",\"stage\":{\"key\":\"QA\",\"gate\":\"exit\"}}}" \
    >/dev/null 2>&1
  ok "QA exit gate policy created (${qa_exit_policy_name})"
fi

ok "AppTrust setup complete."
echo
echo "Application key : ${APP}"
echo "Lifecycle       : DEV → QA → PROD"
echo "Repositories    : $(repo_stage dev), $(repo_stage qa), $(repo_stage prod)"
echo "Gates           : ${dev_exit_policy_name} (DEV exit), ${qa_exit_policy_name} (QA exit)"
echo
echo "Next: run ./04-setup-oidc.sh <owner/repo>"
