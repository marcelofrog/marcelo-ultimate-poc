#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 03a-setup-signing-key.sh
#
# End-to-end key provisioning for JFrog Evidence signing.
#
#   1. Generate an ECDSA P-256 keypair via `jf evd gen-keys`. The CLI writes
#      <alias>.key (private, chmod 600) and <alias>.pub (public) and
#      automatically registers the public key in the JFrog trusted-keys store.
#   2. Upload the PRIVATE key as a GitHub Actions repository secret named
#      POC_EVD_SIGNING_KEY using `gh secret set`.
#   3. Store the key alias as the repo variable POC_EVD_KEY_ALIAS so workflows
#      can pass the right --key-alias without hard-coding it.
#
# Idempotent: if both the local private key file and the JFrog alias already
# exist the generation step is skipped. If either is missing the key is
# (re-)generated so JFrog and local disk stay in sync. The GitHub secret is
# always re-uploaded so it matches whatever key is currently on disk.
# -----------------------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
preflight jf jq curl gh
load_env

APP="$POC_APP_NAME"
KEY_ALIAS="${APP}-evd-key"
KEY_DIR="${REPO_ROOT}/evidence/keys"
PRIV_FILE="${KEY_DIR}/${KEY_ALIAS}.key"
PUB_FILE="${KEY_DIR}/${KEY_ALIAS}.pub"

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

# ---------- 1. keypair -------------------------------------------------------
# `jf evd gen-keys` refuses to overwrite existing files, so we must remove
# any stale material (wrong format, or JFrog alias missing) before regenerating.
if [[ -f "$PRIV_FILE" ]] && evidence_key_exists "$KEY_ALIAS"; then
  ok "signing key already present and registered (alias: ${KEY_ALIAS})"
else
  if [[ -f "$PRIV_FILE" ]] || [[ -f "$PUB_FILE" ]]; then
    warn "stale key files found (JFrog alias not registered) — removing and regenerating"
    # Also remove legacy .pem format from the old openssl-based flow.
    rm -f "${KEY_DIR}/${KEY_ALIAS}.pem" "${KEY_DIR}/${KEY_ALIAS}.key" "${KEY_DIR}/${KEY_ALIAS}.pub"
  fi
  log "generating ECDSA P-256 signing keypair (alias: ${KEY_ALIAS})"
  jf evd gen-keys \
    --key-alias "${KEY_ALIAS}" \
    --key-file-path "${KEY_DIR}" \
    --key-file-name "${KEY_ALIAS}" \
    --upload-public-key=true
  chmod 600 "$PRIV_FILE"
  ok "private key: ${PRIV_FILE}"
  ok "public key registered in JFrog trusted-keys store (alias: ${KEY_ALIAS})"
fi

# ---------- 2. push PRIVATE key to GitHub Actions secret ---------------------
: "${POC_GITHUB_REPO:?POC_GITHUB_REPO must be set in setup/.env}"

secret_name="POC_EVD_SIGNING_KEY"

log "uploading private key as GitHub repo secret ${secret_name} on ${POC_GITHUB_REPO}"
gh secret set "$secret_name" --repo "$POC_GITHUB_REPO" < "$PRIV_FILE"
ok "GitHub secret ${secret_name} set"

gh variable set POC_EVD_KEY_ALIAS --repo "$POC_GITHUB_REPO" --body "$KEY_ALIAS" >/dev/null
ok "GitHub variable POC_EVD_KEY_ALIAS = ${KEY_ALIAS}"

# ---------- summary ----------------------------------------------------------
cat <<EOF

────────────────────────────────────────────────────────────────────────────
Signing key ready.

  Local private key : ${PRIV_FILE}   (chmod 600, keep out of git)
  Local public key  : ${PUB_FILE}
  JFrog alias       : ${KEY_ALIAS}
  GitHub secret     : ${secret_name}
  GitHub variable   : POC_EVD_KEY_ALIAS

The build workflow will use this key to sign:
  • the test-results evidence attestation
  • the docker image (image-digest attestation)
  • the AppTrust application version (SLSA-style provenance)

The promotion workflows will use it to sign the promotion event itself.
────────────────────────────────────────────────────────────────────────────
EOF
