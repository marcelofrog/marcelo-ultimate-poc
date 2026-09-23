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
STAGE_DEV="$(lifecycle_stage dev)"
STAGE_QA="$(lifecycle_stage qa)"
STAGE_PROD="$(lifecycle_stage prod)"

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

# =========== 0b. Lifecycle environments ======================================
log "Ensuring lifecycle environments exist"
for stage in dev qa prod; do
  ensure_environment "$(lifecycle_stage "$stage")"
done
ensure_project_lifecycle

# =========== 1. Stage repositories ===========================================
create_local_docker() {
  local key="$1" stage="$2"
  if repo_exists "$key"; then
    ok "local docker repo already exists: $key"
    return
  fi
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
  # The stage environment is NOT set here: {project}-DEV/QA/PROD are project
  # environments, and Artifactory rejects (HTTP 400) an environment the repo's
  # project does not own. The assignment loop below sets projectKey and
  # environments together.
  ok "created local docker repo: $key (stage ${stage}, env applied at project assignment)"
}

log "Creating stage-scoped local docker repositories"
create_local_docker "$(repo_stage dev)"  dev
create_local_docker "$(repo_stage qa)"   qa
create_local_docker "$(repo_stage prod)" prod

# Assign repos to the JFrog project and apply the stage environment in the SAME
# call. Order matters: the stages are project environments, so a repo can only
# carry {project}-DEV/QA/PROD once it belongs to that project — tagging first
# fails with HTTP 400. Sending projectKey + environments together satisfies both.
# Runs for every stage repo, including ones that already existed.
log "Assigning stage repos to project '${PROJECT}'"
for stage in dev qa prod; do
  repo="$(repo_stage "$stage")"
  stage_env="$(lifecycle_stage "$stage")"
  code="$(jf rt curl -sS -o /dev/null -w '%{http_code}' -X POST "api/repositories/${repo}" \
    -H "Content-Type: application/json" \
    -d "{\"projectKey\":\"${PROJECT}\",\"environments\":[\"${stage_env}\"]}")"
  [[ "$code" == "200" ]] || die "failed to assign repo ${repo} to project ${PROJECT} with env ${stage_env} (HTTP ${code})"
  ok "repo ${repo} → project=${PROJECT}, env=${stage_env}"
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
  local resp
  resp="$(rt_api PUT "/access/api/v1/projects/${PROJECT}/groups/${group}" \
    "{\"roles\":[${roles_json}]}" 2>/dev/null)" \
    || die "failed to assign roles [$*] to group '${group}': ${resp}"
  ok "project group roles: ${group} → $*"
}

# Custom role: AppTrust Manager predefined role only covers the project's
# default DEV+PROD stages. Promoting to QA requires a role whose environment
# scope includes the project-prefixed QA stage.
# CUSTOM type roles can cover all three; CUSTOM_GLOBAL is rejected by this API.
PROMOTER_ROLE="apptrust-promoter"
if rt_api GET "/access/api/v1/projects/${PROJECT}/roles/${PROMOTER_ROLE}" 2>/dev/null | jq -e '.name' >/dev/null 2>&1; then
  ok "custom role '${PROMOTER_ROLE}' already exists"
else
  role_resp="$(rt_api POST "/access/api/v1/projects/${PROJECT}/roles" \
    "{\"name\":\"${PROMOTER_ROLE}\",\"type\":\"CUSTOM\",\"description\":\"Promote AppTrust versions across all stages (${STAGE_DEV}→${STAGE_QA}→${STAGE_PROD})\",\"environments\":[\"${STAGE_DEV}\",\"${STAGE_QA}\",\"${STAGE_PROD}\"],\"actions\":[\"READ_APPLICATION\",\"READ_APPLICATION_VERSION\",\"PROMOTE_APPLICATION_VERSION\"]}" 2>/dev/null)" \
    || die "failed to create custom role '${PROMOTER_ROLE}': ${role_resp}"
  ok "created custom role '${PROMOTER_ROLE}' (${STAGE_DEV}+${STAGE_QA}+${STAGE_PROD}, PROMOTE_APPLICATION_VERSION)"
fi

# Developer: CREATE_APPLICATION_VERSION + DEPLOY_BUILD (needed for build.yml).
# apptrust-promoter: PROMOTE_APPLICATION_VERSION so build.yml can promote
# the newly-created version from unassigned → DEV in the same workflow run.
assign_group_roles "$(group_stage dev)"  "Developer" "${PROMOTER_ROLE}"
# Contributor + AppTrust Manager (admin tasks) + apptrust-promoter (QA env scope)
assign_group_roles "$(group_stage qa)"   "Contributor" "AppTrust Manager" "${PROMOTER_ROLE}"
assign_group_roles "$(group_stage prod)" "Contributor" "AppTrust Manager" "${PROMOTER_ROLE}"

# =========== 4. Promotion gates (Unified Policy API) =========================
# CLI-gap: `jf apptrust` has no gate-management subcommand; use the unified
# policy REST API at /unifiedpolicy/api/v1. Stage keys are {project}-{STAGE}.
#
# Three gates are created on the application lifecycle:
#   {project}-DEV  exit  — security: block if applicable CVE score >= CVE_THRESHOLD
#   {project}-QA   exit  — evidence: block if no test-results evidence is attached
#   {project}-PROD entry — block unless the QA exit gate was certified
#
# The stages must already be part of the project lifecycle (ensure_project_lifecycle
# above), otherwise every policy here fails with HTTP 400 "Selected stage is not
# available for projects: {project}".
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

# create_policy NAME JSON — POST the policy and surface the API error body on
# failure. Without this the response is swallowed and `set -e` aborts the run
# with no explanation (e.g. "Selected stage is not available for projects").
create_policy() {
  local name="$1" payload="$2" resp
  if ! resp="$(rt_api POST "/unifiedpolicy/api/v1/policies" "$payload" 2>/dev/null)"; then
    die "failed to create gate policy '${name}': ${resp}"
  fi
}

# --- 4c. DEV exit gate policy: security rule ---------------------------------
if unified_policy_exists "$dev_exit_policy_name"; then
  ok "${STAGE_DEV} exit gate policy already exists (${dev_exit_policy_name})"
else
  log "creating ${STAGE_DEV} exit gate policy (CVE >= ${CVE_THRESHOLD})"
  create_policy "$dev_exit_policy_name" \
    "{\"name\":\"${dev_exit_policy_name}\",\"description\":\"Block ${STAGE_DEV}→${STAGE_QA} promotion if applicable CVE >= ${CVE_THRESHOLD}\",\"mode\":\"block\",\"enabled\":true,\"rule_ids\":[\"${SECURITY_RULE_ID}\"],\"scope\":{\"type\":\"application\",\"application_keys\":[\"${APP}\"]},\"action\":{\"type\":\"certify_to_gate\",\"stage\":{\"key\":\"${STAGE_DEV}\",\"gate\":\"exit\"}}}"
  ok "${STAGE_DEV} exit gate policy created (${dev_exit_policy_name})"
fi

# --- 4d. QA exit gate policy: evidence rule ----------------------------------
if unified_policy_exists "$qa_exit_policy_name"; then
  ok "${STAGE_QA} exit gate policy already exists (${qa_exit_policy_name})"
else
  log "creating ${STAGE_QA} exit gate policy (test-results evidence required)"
  create_policy "$qa_exit_policy_name" \
    "{\"name\":\"${qa_exit_policy_name}\",\"description\":\"Block ${STAGE_QA}→${STAGE_PROD} promotion unless test-results evidence is attached\",\"mode\":\"block\",\"enabled\":true,\"rule_ids\":[\"${EVIDENCE_RULE_ID}\"],\"scope\":{\"type\":\"application\",\"application_keys\":[\"${APP}\"]},\"action\":{\"type\":\"certify_to_gate\",\"stage\":{\"key\":\"${STAGE_QA}\",\"gate\":\"exit\"}}}"
  ok "${STAGE_QA} exit gate policy created (${qa_exit_policy_name})"
fi

# --- 4e. PROD entry gate: requires QA exit certification ---------------------
# Uses the predefined system rule "QA.Exit AppTrust Gate Certification exist"
# (rule id 2027, template 1008) — blocks entry into prod unless QA exit was
# certified. gate="entry" rather than "release": only the platform-global PROD
# stage is release-category, project stages are always promote-category, and
# promote-qa-to-prod.yml reaches prod through version-promote (an entry event).
if unified_policy_exists "$prod_release_policy_name"; then
  ok "${STAGE_PROD} entry gate policy already exists (${prod_release_policy_name})"
else
  log "creating ${STAGE_PROD} entry gate policy (${STAGE_QA} exit certification required)"
  create_policy "$prod_release_policy_name" \
    "{\"name\":\"${prod_release_policy_name}\",\"description\":\"Block promotion to ${STAGE_PROD} unless ${STAGE_QA} exit gate was certified\",\"mode\":\"block\",\"enabled\":true,\"rule_ids\":[\"${QA_EXIT_CERT_RULE_ID}\"],\"scope\":{\"type\":\"application\",\"application_keys\":[\"${APP}\"]},\"action\":{\"type\":\"certify_to_gate\",\"stage\":{\"key\":\"${STAGE_PROD}\",\"gate\":\"entry\"}}}"
  ok "${STAGE_PROD} entry gate policy created (${prod_release_policy_name})"
fi

ok "AppTrust setup complete."
echo
echo "Application key : ${APP}"
echo "Lifecycle       : ${STAGE_DEV} → ${STAGE_QA} → ${STAGE_PROD}"
echo "Repositories    : $(repo_stage dev), $(repo_stage qa), $(repo_stage prod)"
echo "Gates           : ${dev_exit_policy_name} (${STAGE_DEV} exit), ${qa_exit_policy_name} (${STAGE_QA} exit), ${prod_release_policy_name} (${STAGE_PROD} entry)"
echo
echo "Next: run ./04-setup-oidc.sh <owner/repo>"
