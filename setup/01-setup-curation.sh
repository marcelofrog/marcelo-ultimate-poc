#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 01-setup-curation.sh
#
# Creates the three curated remote repositories (PyPI, npm, Docker Hub) and
# defines the three Curation blocking policies required for the POC:
#   - malicious packages
#   - packages with no declared license
#   - immature packages (< 7 days old)
#
# Idempotent: re-running is safe; existing objects are detected and skipped.
# -----------------------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
preflight jf jq curl
load_env

APP="$POC_APP_NAME"

# =========== 1. Remote repositories ==========================================
log "Creating curated remote repositories for ${APP}"

create_remote() {
  local key="$1" package_type="$2" url="$3" template="$4"
  if repo_exists "$key"; then
    ok "remote repo already exists: $key"
    return
  fi
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<JSON
{
  "key": "${key}",
  "rclass": "remote",
  "packageType": "${package_type}",
  "url": "${url}",
  "xrayIndex": "true",
  "description": "POC ${APP} curated remote for ${package_type}",
  "notes": "Created by 01-setup-curation.sh"
}
JSON
  jf_admin rt repo-create "$tmp"
  rm -f "$tmp"
  # CLI-gap: jf rt repo-create template does not support the 'curated' key.
  # Set it via the Artifactory REST API after creation.
  jf rt curl -sS -XPOST "api/repositories/${key}" \
    -H "Content-Type: application/json" \
    -d '{"curated":true}' >/dev/null
  ok "created remote repo: $key ($package_type)"
}

create_remote "$(repo_pypi)"   "pypi"   "https://files.pythonhosted.org"   pypi
create_remote "$(repo_npm)"    "npm"    "https://registry.npmjs.org"       npm
create_remote "$(repo_docker)" "docker" "https://registry-1.docker.io"     docker

# =========== 2. Curation blocking policies ===================================
log "Creating Curation blocking policies"

# CLI-gap: `jf curation` is not a CLI command in this version.
# Policies are managed via POST /xray/api/v1/curation/policies.
# Built-in condition IDs:  1=malicious  8=no-license
# Custom conditions are embedded inline in the policy body.

REPOS="[\"$(repo_pypi)\",\"$(repo_npm)\",\"$(repo_docker)\"]"

apply_policy() {
  local name="$1" body="$2"
  if curation_policy_exists "$name"; then
    warn "curation policy '$name' already exists — skipping"
    return
  fi
  local stderr http_status
  # jf api writes "Http Status: NNN" to stderr; capture stderr only.
  stderr="$(jf api /xray/api/v1/curation/policies -X POST \
    -H "Content-Type: application/json" --data "$body" 2>&1 >/dev/null || true)"
  http_status="$(printf '%s\n' "$stderr" | awk '/Http Status:/{print $NF; exit}')"
  if [[ "$http_status" =~ ^2 ]]; then
    ok "curation policy created: $name"
  else
    # Print the response body for diagnosis
    jf api /xray/api/v1/curation/policies -X POST \
      -H "Content-Type: application/json" --data "$body" 2>/dev/null || true
    die "failed to create curation policy '$name' (HTTP ${http_status:-unknown})"
  fi
}

# Malicious — built-in condition 1
apply_policy "$(policy_id curation-malicious)" "$(cat <<JSON
{
  "name":                 "$(policy_id curation-malicious)",
  "scope":                "specific_repos",
  "policy_action":        "block",
  "condition_id":         "1",
  "repo_include":         ${REPOS},
  "waiver_request_config":"forbidden",
  "block_from_cache":     true,
  "share_with_federation":false
}
JSON
)"

# No identified license — built-in condition 8
apply_policy "$(policy_id curation-no-license)" "$(cat <<JSON
{
  "name":                 "$(policy_id curation-no-license)",
  "scope":                "specific_repos",
  "policy_action":        "block",
  "condition_id":         "8",
  "repo_include":         ${REPOS},
  "waiver_request_config":"forbidden",
  "block_from_cache":     true,
  "share_with_federation":false
}
JSON
)"

# Immature < 7 days — custom condition using the isImmature template.
# CLI-gap: the policy API does not accept inline condition objects; a condition
# must be created separately to obtain its numeric id, which is then referenced
# via condition_id in the policy body.
immature_cond_name="$(policy_id immature-7d)"
IMMATURE_COND_ID="$(curation_condition_id_by_name "$immature_cond_name")"
if [[ -z "$IMMATURE_COND_ID" ]]; then
  immature_resp="$(jf api /xray/api/v1/curation/conditions -X POST \
    -H "Content-Type: application/json" \
    --data "{\"name\":\"${immature_cond_name}\",\"condition_template_id\":\"isImmature\",\"risk_type\":\"operational\",\"param_values\":[{\"param_id\":\"package_age_days\",\"value\":7}]}" \
    2>/dev/null)"
  IMMATURE_COND_ID="$(echo "$immature_resp" | jq -r '.id // empty')"
  [[ -n "$IMMATURE_COND_ID" ]] || die "failed to create immature curation condition — response: $immature_resp"
  ok "created curation condition: ${immature_cond_name} (id=${IMMATURE_COND_ID})"
else
  ok "curation condition already exists: ${immature_cond_name} (id=${IMMATURE_COND_ID})"
fi

apply_policy "$(policy_id curation-immature)" "$(cat <<JSON
{
  "name":                 "$(policy_id curation-immature)",
  "scope":                "specific_repos",
  "policy_action":        "block",
  "condition_id":         "${IMMATURE_COND_ID}",
  "repo_include":         ${REPOS},
  "waiver_request_config":"forbidden",
  "block_from_cache":     true,
  "share_with_federation":false
}
JSON
)"

ok "Curation setup complete."
echo
echo "Next: run ./02-setup-users.sh"
