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

# Assign repos to the JFrog project and (re-)apply the correct environment tag.
# The project assignment via POST api/repositories resets the environment array
# to ["DEV"], so the tag must be explicitly set afterwards.
log "Assigning stage repos to project '${PROJECT}'"
for stage in dev qa prod; do
  repo="$(repo_stage "$stage")"
  stage_upper="$(echo "$stage" | tr '[:lower:]' '[:upper:]')"
  jf rt curl -sS -X POST "api/repositories/${repo}" \
    -H "Content-Type: application/json" \
    -d "{\"projectKey\":\"${PROJECT}\",\"environments\":[\"${stage_upper}\"]}" >/dev/null
  ok "repo ${repo} → project=${PROJECT}, env=${stage_upper}"
done

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
# Re-apply all permission targets now that the stage-local repos exist.
# 02-setup-users.sh ran first and created permissions, but at that point the
# stage-local repos did not yet exist (they are created above in section 1),
# so the Artifactory API silently dropped them from the repo list. Re-applying
# here guarantees all repos are present: stage-locals + curated remotes.
log "Re-applying permission targets (stage repos now exist)"

apply_perm() {
  local name="$1" group="$2" repos_json="$3" actions="${4:-read,annotate,write}"
  local actions_json; actions_json="[$(echo "$actions" | sed 's/[^,]*/\"&\"/g')]"
  jf rt curl -sS -X PUT -H "Content-Type: application/json" \
    --data "{
      \"name\": \"${name}\",
      \"repo\": {
        \"include-patterns\": [\"**\"],
        \"exclude-patterns\": [],
        \"repositories\": ${repos_json},
        \"actions\": { \"groups\": { \"${group}\": ${actions_json} } }
      }
    }" "api/v2/security/permissions/${name}" >/dev/null
  ok "permission target: ${name}"
}

DEV_REPOS="[\"$(repo_stage dev)\",\"$(repo_pypi)\",\"$(repo_npm)\",\"$(repo_docker)\"]"
QA_REPOS="[\"$(repo_stage qa)\",\"$(repo_pypi)\",\"$(repo_npm)\",\"$(repo_docker)\"]"
PROD_REPOS="[\"$(repo_stage prod)\",\"$(repo_pypi)\",\"$(repo_npm)\",\"$(repo_docker)\"]"

apply_perm "$(perm_target dev  writer)"   "$(group_stage dev)"  "$DEV_REPOS"                                                    "read,annotate,write,delete"
apply_perm "$(perm_target qa   writer)"   "$(group_stage qa)"   "$QA_REPOS"
apply_perm "$(perm_target prod writer)"   "$(group_stage prod)" "$PROD_REPOS"
apply_perm "$(perm_target qa   promoter)" "$(group_stage qa)"   "[\"$(repo_stage dev)\",\"$(repo_stage qa)\"]"
apply_perm "$(perm_target prod promoter)" "$(group_stage prod)" "[\"$(repo_stage qa)\",\"$(repo_stage prod)\"]"

# Build-info permission (v2 build section — must be separate from repo section).
BUILD_INFO_PERM="$(prefix dev-build-info)"
jf rt curl -sS -X PUT -H "Content-Type: application/json" \
  --data "{
    \"name\": \"${BUILD_INFO_PERM}\",
    \"build\": {
      \"include-patterns\": [\"${APP}/**\"],
      \"exclude-patterns\": [],
      \"repositories\": [\"artifactory-build-info\"],
      \"actions\": { \"groups\": { \"$(group_stage dev)\": [\"read\",\"write\",\"annotate\",\"delete\",\"manage\",\"managedXrayMeta\"] } }
    }
  }" "api/v2/security/permissions/${BUILD_INFO_PERM}" >/dev/null
ok "build-info permission target: ${BUILD_INFO_PERM}"

# =========== 3b. Project group roles =========================================
# Assign lifecycle-stage groups to the JFrog project with the appropriate role.
# The Developer role grants CREATE_APPLICATION_VERSION (needed by build.yml)
# and DEPLOY_BUILD (needed for jf rt build-publish).
log "Assigning stage groups to JFrog project '${PROJECT}'"
assign_group_roles() {
  local group="$1"; shift
  local roles_json; roles_json="$(printf '"%s",' "$@" | sed 's/,$//')"
  rt_api PUT "/access/api/v1/projects/${PROJECT}/groups/${group}" \
    "{\"roles\":[${roles_json}]}" >/dev/null
  ok "project group roles: ${group} → $*"
}

# Custom role: AppTrust Manager predefined role only covers DEV+PROD environments.
# Promoting to QA requires a role whose environment scope includes QA.
# CUSTOM type roles can cover all three; CUSTOM_GLOBAL is rejected by this API.
PROMOTER_ROLE="apptrust-promoter"
if rt_api GET "/access/api/v1/projects/${PROJECT}/roles/${PROMOTER_ROLE}" 2>/dev/null | jq -e '.name' >/dev/null 2>&1; then
  ok "custom role '${PROMOTER_ROLE}' already exists"
else
  rt_api POST "/access/api/v1/projects/${PROJECT}/roles" \
    "{\"name\":\"${PROMOTER_ROLE}\",\"type\":\"CUSTOM\",\"description\":\"Promote AppTrust versions across all stages (DEV→QA→PROD)\",\"environments\":[\"DEV\",\"QA\",\"PROD\"],\"actions\":[\"READ_APPLICATION\",\"READ_APPLICATION_VERSION\",\"PROMOTE_APPLICATION_VERSION\"]}" >/dev/null
  ok "created custom role '${PROMOTER_ROLE}' (DEV+QA+PROD, PROMOTE_APPLICATION_VERSION)"
fi

# Developer: CREATE_APPLICATION_VERSION + DEPLOY_BUILD (needed for build.yml)
assign_group_roles "$(group_stage dev)"  "Developer"
# Contributor + AppTrust Manager (admin tasks) + apptrust-promoter (QA env scope)
assign_group_roles "$(group_stage qa)"   "Contributor" "AppTrust Manager" "${PROMOTER_ROLE}"
assign_group_roles "$(group_stage prod)" "Contributor" "AppTrust Manager" "${PROMOTER_ROLE}"

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
prod_release_policy_name="$(prefix prod-release-gate)"
# Predefined rule id for "QA.Exit AppTrust Gate Certification exist" (template 1008).
# This is a system rule — it checks that the QA exit gate was certified before releasing.
QA_EXIT_CERT_RULE_ID="2027"

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

# --- 4e. PROD release gate: requires QA exit certification -------------------
# Uses the predefined system rule "QA.Exit AppTrust Gate Certification exist"
# (rule id 2027, template 1008) — blocks release unless QA exit was certified.
# gate="release" is the AppTrust gate type that appears in the UI as "Release Gate".
if unified_policy_exists "$prod_release_policy_name"; then
  ok "PROD release gate policy already exists (${prod_release_policy_name})"
else
  log "creating PROD release gate policy (QA exit certification required)"
  rt_api POST "/unifiedpolicy/api/v1/policies" \
    "{\"name\":\"${prod_release_policy_name}\",\"description\":\"Block release to PROD unless QA exit gate was certified\",\"mode\":\"block\",\"enabled\":true,\"rule_ids\":[\"${QA_EXIT_CERT_RULE_ID}\"],\"scope\":{\"type\":\"application\",\"application_keys\":[\"${APP}\"]},\"action\":{\"type\":\"certify_to_gate\",\"stage\":{\"key\":\"PROD\",\"gate\":\"release\"}}}" \
    >/dev/null 2>&1
  ok "PROD release gate policy created (${prod_release_policy_name})"
fi

ok "AppTrust setup complete."
echo
echo "Application key : ${APP}"
echo "Lifecycle       : DEV → QA → PROD"
echo "Repositories    : $(repo_stage dev), $(repo_stage qa), $(repo_stage prod)"
echo "Gates           : ${dev_exit_policy_name} (DEV exit), ${qa_exit_policy_name} (QA exit), ${prod_release_policy_name} (PROD release)"
echo
echo "Next: run ./04-setup-oidc.sh <owner/repo>"
