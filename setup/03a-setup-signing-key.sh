#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 03a-setup-signing-key.sh
#
# End-to-end key provisioning. This POC owns BOTH of its signing keys so it
# never depends on pre-existing platform keys (notably the shared
# `default-lifecycle-key`, which is created automatically when no key is
# specified and is not under this project's control).
#
# Two keys, because there are two signing paths:
#
#   Evidence key (client-side) — signs the `jf evd create` attestations on the
#   GitHub runner. Only the PUBLIC half goes to JFrog, so the private key can
#   stay in a GitHub secret.
#
#   Lifecycle key (server-side) — signs the AppTrust application-version
#   manifest (release-bundle.json.evd), which Artifactory produces itself at
#   version-create time. That signature is made inside the platform, so the
#   PRIVATE half must be uploaded to Artifactory Keys Management. Copy
#   promotion re-verifies this signature, so a mismatch here blocks DEV→QA.
#
# Steps:
#   1. Generate an ECDSA P-256 evidence keypair via `jf evd gen-keys`. The CLI
#      writes <alias>.key (private, chmod 600) and <alias>.pub (public); the
#      public key is registered in the JFrog trusted-keys store.
#   2. Generate an RSA-2048 lifecycle keypair via openssl and upload it to
#      Artifactory Keys Management as the key pair <app>-lifecycle-key. The
#      public half is also added to the trusted-keys store so verification
#      resolves it. AppTrust supports GPG/RSA keys for version signing, which
#      is why this one is not the ECDSA evidence key.
#   3. Upload the evidence PRIVATE key as a GitHub Actions repository secret
#      named POC_EVD_SIGNING_KEY using `gh secret set`.
#   4. Store the key names as the repo variables POC_EVD_KEY_ALIAS and
#      POC_LIFECYCLE_KEY_NAME so workflows do not hard-code them.
#
# Idempotent: if both the local private key file and the JFrog registration
# already exist the generation step is skipped. If either is missing the key is
# (re-)generated so JFrog and local disk stay in sync. The GitHub secret is
# always re-uploaded so it matches whatever key is currently on disk.
# -----------------------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
preflight jf jq curl gh openssl
load_env

APP="$POC_APP_NAME"
KEY_ALIAS="${APP}-evd-key"
KEY_DIR="${REPO_ROOT}/evidence/keys"
PRIV_FILE="${KEY_DIR}/${KEY_ALIAS}.key"
PUB_FILE="${KEY_DIR}/${KEY_ALIAS}.pub"

LC_KEY_NAME="${APP}-lifecycle-key"
LC_PRIV_FILE="${KEY_DIR}/${LC_KEY_NAME}.private.pem"
LC_PUB_FILE="${KEY_DIR}/${LC_KEY_NAME}.public.pem"

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

# Trusted keys live at /artifactory/api/security/keys/trusted (DELETE by kid,
# POST to add). Both keys register their public half here.
_upload_trusted_key() {
  local alias="$1" pub_file="$2"
  # Delete existing alias if present (kid-based).
  local kid; kid="$(evidence_key_kid_by_alias "$alias" 2>/dev/null || true)"
  if [[ -n "$kid" ]]; then
    jf api "/artifactory/api/security/keys/trusted/${kid}" -X DELETE >/dev/null 2>&1 || true
  fi
  jf api "/artifactory/api/security/keys/trusted" -X POST \
    -H "Content-Type: application/json" \
    --data "{\"alias\":\"${alias}\",\"key\":$(jq -Rs . < "$pub_file")}" >/dev/null
}

# ---------- 1. evidence keypair ----------------------------------------------
# `jf evd gen-keys` refuses to overwrite existing files, so we must remove
# any stale material before regenerating.
if [[ -f "$PRIV_FILE" ]] && evidence_key_exists "$KEY_ALIAS"; then
  # Verify local public key matches what JFrog has stored.
  local_pub="$(cat "$PUB_FILE" | tr -d '\n')"
  jfrog_pub="$(jf api "/artifactory/api/security/keys/trusted" -X GET 2>/dev/null \
    | jq -r --arg a "$KEY_ALIAS" '.keys[] | select(.alias == $a) | .key' | tr -d '\n')"
  if [[ "$local_pub" == "$jfrog_pub" ]]; then
    ok "signing key already present and registered (alias: ${KEY_ALIAS})"
  else
    warn "local public key differs from JFrog trusted-keys store — re-uploading"
    _upload_trusted_key "$KEY_ALIAS" "$PUB_FILE"
    ok "public key updated in JFrog trusted-keys store (alias: ${KEY_ALIAS})"
  fi
else
  if [[ -f "$PRIV_FILE" ]] || [[ -f "$PUB_FILE" ]]; then
    warn "stale key files found (JFrog alias not registered) — removing and regenerating"
    # Also remove legacy .pem format from the old openssl-based flow.
    rm -f "${KEY_DIR}/${KEY_ALIAS}.pem" "${KEY_DIR}/${KEY_ALIAS}.key" "${KEY_DIR}/${KEY_ALIAS}.pub"
  fi
  log "generating ECDSA P-256 signing keypair (alias: ${KEY_ALIAS})"
  # Generate locally only; upload is handled below via REST to stay idempotent.
  jf evd gen-keys \
    --key-alias "${KEY_ALIAS}" \
    --key-file-path "${KEY_DIR}" \
    --key-file-name "${KEY_ALIAS}" \
    --upload-public-key=false
  chmod 600 "$PRIV_FILE"
  ok "private key: ${PRIV_FILE}"
  _upload_trusted_key "$KEY_ALIAS" "$PUB_FILE"
  ok "public key registered in JFrog trusted-keys store (alias: ${KEY_ALIAS})"
fi

# ---------- 2. lifecycle signing key pair ------------------------------------
# Uploaded as a key PAIR (private + public) because Artifactory signs the
# application-version manifest itself; a public-only trusted key cannot be
# used for that. POST replaces an existing pair of the same name.
_upload_lifecycle_keypair() {
  local payload="${KEY_DIR}/.${LC_KEY_NAME}.payload.json"
  jq -n \
    --arg pairName "$LC_KEY_NAME" \
    --arg alias    "$LC_KEY_NAME" \
    --rawfile privateKey "$LC_PRIV_FILE" \
    --rawfile publicKey  "$LC_PUB_FILE" \
    '{pairName: $pairName, pairType: "RSA", alias: $alias,
      privateKey: $privateKey, publicKey: $publicKey}' > "$payload"
  chmod 600 "$payload"
  # --input keeps the PEM bodies off the process command line.
  jf api "/artifactory/api/security/keypair" -X POST \
    -H "Content-Type: application/json" --input "$payload" >/dev/null
  rm -f "$payload"
}

if [[ -f "$LC_PRIV_FILE" ]] && keypair_exists "$LC_KEY_NAME"; then
  ok "lifecycle signing key pair already present (${LC_KEY_NAME})"
else
  if [[ -f "$LC_PRIV_FILE" ]] || [[ -f "$LC_PUB_FILE" ]]; then
    warn "stale lifecycle key files found (not registered in Artifactory) — regenerating"
    rm -f "$LC_PRIV_FILE" "$LC_PUB_FILE"
  fi
  log "generating RSA-2048 lifecycle signing keypair (${LC_KEY_NAME})"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$LC_PRIV_FILE" 2>/dev/null
  chmod 600 "$LC_PRIV_FILE"
  openssl rsa -in "$LC_PRIV_FILE" -pubout -out "$LC_PUB_FILE" 2>/dev/null
  ok "private key: ${LC_PRIV_FILE}"
  _upload_lifecycle_keypair
  ok "key pair registered in Artifactory Keys Management (${LC_KEY_NAME})"
fi

# Derivable from the private key, so recover it rather than forcing a rotation.
[[ -f "$LC_PUB_FILE" ]] || openssl rsa -in "$LC_PRIV_FILE" -pubout -out "$LC_PUB_FILE" 2>/dev/null

_upload_trusted_key "$LC_KEY_NAME" "$LC_PUB_FILE"
ok "lifecycle public key registered in JFrog trusted-keys store (${LC_KEY_NAME})"

# ---------- 3. push PRIVATE key to GitHub Actions secret ---------------------
: "${POC_GITHUB_REPO:?POC_GITHUB_REPO must be set in setup/.env}"

secret_name="POC_EVD_SIGNING_KEY"

log "uploading private key as GitHub repo secret ${secret_name} on ${POC_GITHUB_REPO}"
gh secret set "$secret_name" --repo "$POC_GITHUB_REPO" < "$PRIV_FILE"
ok "GitHub secret ${secret_name} set"

# ---------- 4. key names as repo variables -----------------------------------
gh variable set POC_EVD_KEY_ALIAS --repo "$POC_GITHUB_REPO" --body "$KEY_ALIAS" >/dev/null
ok "GitHub variable POC_EVD_KEY_ALIAS = ${KEY_ALIAS}"

gh variable set POC_LIFECYCLE_KEY_NAME --repo "$POC_GITHUB_REPO" --body "$LC_KEY_NAME" >/dev/null
ok "GitHub variable POC_LIFECYCLE_KEY_NAME = ${LC_KEY_NAME}"

# ---------- summary ----------------------------------------------------------
cat <<EOF

────────────────────────────────────────────────────────────────────────────
Signing keys ready. This POC now signs with its own keys only.

Evidence key (signs on the GitHub runner)
  Local private key : ${PRIV_FILE}   (chmod 600, keep out of git)
  Local public key  : ${PUB_FILE}
  JFrog alias       : ${KEY_ALIAS}   (trusted keys)
  GitHub secret     : ${secret_name}
  GitHub variable   : POC_EVD_KEY_ALIAS

Lifecycle key (signs inside Artifactory)
  Local private key : ${LC_PRIV_FILE}   (chmod 600, keep out of git)
  Local public key  : ${LC_PUB_FILE}
  JFrog key pair    : ${LC_KEY_NAME}   (Keys Management + trusted keys)
  GitHub variable   : POC_LIFECYCLE_KEY_NAME

The build workflow will use the evidence key to sign:
  • the test-results evidence attestation
  • the docker image (image-digest attestation)
  • the AppTrust application version (SLSA-style provenance)

The promotion workflows will use it to sign the promotion event itself.

The build workflow passes the lifecycle key name to the application-version
create API, so the version manifest that copy promotion re-verifies is signed
by this key instead of the platform's shared default-lifecycle-key.
────────────────────────────────────────────────────────────────────────────
EOF
