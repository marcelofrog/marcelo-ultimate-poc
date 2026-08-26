#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 03a-setup-signing-key.sh
#
# End-to-end key provisioning for JFrog Evidence signing.
#
#   1. Generate an ed25519 keypair locally (openssl). The private key never
#      leaves this machine except via a single scripted `gh secret set` call.
#   2. Register the PUBLIC key with the JFrog Evidence trust store so
#      verifiers can validate signatures at promote time and downstream.
#   3. Upload the PRIVATE key as a GitHub Actions repository secret named
#      POC_EVD_SIGNING_KEY, using the `gh` CLI. If the CLI is not
#      authenticated the script falls back to printing the manual command.
#
# The same key is later used by build.yml to sign:
#     - test-results evidence
#     - docker image evidence (image digest attestation)
#     - AppTrust application version release evidence (SLSA-style provenance)
# and by the promotion workflows to sign the promotion event itself.
#
# Idempotent: existing keypair on disk is reused; existing JFrog trust entry
# and GitHub secret are overwritten with the current key material so the
# whole chain stays consistent.
# -----------------------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
preflight jf jq curl openssl gh
load_env

APP="$POC_APP_NAME"
KEY_ALIAS="${APP}-evd-key"
KEY_DIR="${REPO_ROOT}/evidence/keys"
PRIV_FILE="${KEY_DIR}/${KEY_ALIAS}.pem"
PUB_FILE="${KEY_DIR}/${KEY_ALIAS}.pub"

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

# ---------- 1. keypair -------------------------------------------------------
if [[ -f "$PRIV_FILE" ]]; then
  ok "signing key already present at ${PRIV_FILE} (reusing)"
else
  log "generating ed25519 signing keypair"
  openssl genpkey -algorithm ed25519 -out "$PRIV_FILE"
  chmod 600 "$PRIV_FILE"
  ok "private key: ${PRIV_FILE}"
fi

openssl pkey -in "$PRIV_FILE" -pubout -out "$PUB_FILE"
chmod 644 "$PUB_FILE"
ok "public key: ${PUB_FILE}"

# ---------- 2. upload PUBLIC key to JFrog Evidence trust store ---------------
log "registering public key with JFrog Evidence trust store (alias: ${KEY_ALIAS})"

# CLI-gap: no `jf evd key-*` yet, use /evidence/api/v1/keys.
# 201 == created, 409 == already registered under this alias, both OK.
key_payload="$(jq -Rs --arg alias "$KEY_ALIAS" \
    '{alias:$alias, public_key:., algorithm:"ed25519"}' "$PUB_FILE")"
http="$(rt_api_status POST "/evidence/api/v1/keys" "$key_payload")"
case "$http" in
  201|200) ok "public key registered (${http})" ;;
  409)
    # already exists — replace to keep JFrog and local key in sync
    warn "key alias ${KEY_ALIAS} exists — replacing public key"
    http="$(rt_api_status PUT "/evidence/api/v1/keys/${KEY_ALIAS}" "$key_payload")"
    ok "public key updated (${http})"
    ;;
  *) warn "unexpected status ${http} while registering public key" ;;
esac

# ---------- 3. push PRIVATE key to GitHub Actions secret ---------------------
: "${POC_GITHUB_REPO:?POC_GITHUB_REPO must be set in setup/.env}"

secret_name="POC_EVD_SIGNING_KEY"

push_secret_via_gh() {
  # `gh` reuses whatever auth the user already has. If the user is not logged
  # in, tell them how to fix it — we do NOT prompt for tokens here either.
  if ! command -v gh >/dev/null 2>&1; then
    return 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    return 1
  fi
  log "uploading private key as GitHub repo secret ${secret_name} on ${POC_GITHUB_REPO}"
  gh secret set "$secret_name" --repo "$POC_GITHUB_REPO" < "$PRIV_FILE"
  ok "GitHub secret ${secret_name} set"

  # Also stash the alias as a non-secret repo variable so workflows can pass
  # the right --key-alias without hard-coding it.
  gh variable set POC_EVD_KEY_ALIAS --repo "$POC_GITHUB_REPO" --body "$KEY_ALIAS" >/dev/null
  ok "GitHub variable POC_EVD_KEY_ALIAS = ${KEY_ALIAS}"
}

if push_secret_via_gh; then
  :
else
  warn "gh CLI unavailable or not authenticated — you must upload manually:"
  echo
  echo "    gh auth login"
  echo "    gh secret   set ${secret_name}       --repo \"${POC_GITHUB_REPO}\" < \"${PRIV_FILE}\""
  echo "    gh variable set POC_EVD_KEY_ALIAS    --repo \"${POC_GITHUB_REPO}\" --body \"${KEY_ALIAS}\""
  echo
fi

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
