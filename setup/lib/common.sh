#!/usr/bin/env bash
# Common helpers sourced by every setup script.
#
# Authentication model: ALL credentials come from the active `jf` CLI profile.
# The user configures that profile ONCE with `jfrog config add`. No token,
# password, or username is ever read from the environment, prompted for,
# stored in .env, or written to disk by anything under setup/.
# shellcheck disable=SC2034

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$(cd "${_here}/.." && pwd)"
REPO_ROOT="$(cd "${SETUP_DIR}/.." && pwd)"

# ---------- colour output ----------
# Use ANSI-C quoted strings so the escapes are real bytes; this lets the
# heredoc-based error messages render colours without needing echo -e.
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_BOLD=$'\e[1m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi

log()   { echo -e "${C_BLUE}==>${C_RESET} $*"; }
ok()    { echo -e "${C_GREEN}✓${C_RESET}  $*"; }
warn()  { echo -e "${C_YELLOW}!  $*${C_RESET}"; }
die()   { echo -e "${C_RED}✗  $*${C_RESET}" >&2; exit 1; }

# ---------- OS detection -----------------------------------------------------
# POC_OS is one of: macos | debian | fedora | rhel | linux | unknown
detect_os() {
  case "$(uname -s)" in
    Darwin) POC_OS="macos" ;;
    Linux)
      if   command -v apt-get >/dev/null 2>&1; then POC_OS="debian"
      elif command -v dnf     >/dev/null 2>&1; then POC_OS="fedora"
      elif command -v yum     >/dev/null 2>&1; then POC_OS="rhel"
      elif command -v zypper  >/dev/null 2>&1; then POC_OS="suse"
      elif command -v pacman  >/dev/null 2>&1; then POC_OS="arch"
      else                                          POC_OS="linux"
      fi
      ;;
    *) POC_OS="unknown" ;;
  esac
  export POC_OS
}

# ---------- preflight tool verification --------------------------------------
# Returns 0/prints nothing if `tool` is installed and callable.
# On failure: prints platform-specific install hint and exits non-zero.
#
# Usage:
#   preflight jf gh docker jq openssl curl
#
# Every setup script must call this near the top with the tools it needs so
# the user gets a fast, actionable failure rather than a confusing error
# 30 seconds into the run.
preflight() {
  detect_os
  local missing=0
  for tool in "$@"; do
    if command -v "$tool" >/dev/null 2>&1; then
      ok "found $tool ($(_tool_version "$tool"))"
    else
      warn "missing required tool: ${tool}"
      _install_hint "$tool"
      missing=$((missing + 1))
    fi
  done
  if (( missing > 0 )); then
    die "${missing} required tool(s) missing. Install the tool(s) above and re-run."
  fi

  # jf has a version floor — check it here rather than inside every script.
  if command -v jf >/dev/null 2>&1; then
    _require_jf_version "2.60.0"
  fi

  # gh has to be authenticated to be useful for `gh secret set`.
  # We check the AUTH state only if gh was in the required list.
  for tool in "$@"; do
    if [[ "$tool" == "gh" ]]; then
      if ! gh auth status -h github.com >/dev/null 2>&1; then
        die "gh CLI is installed but not authenticated. Run: gh auth login"
      fi
      ok "gh authenticated"
    fi
  done
}

_tool_version() {
  case "$1" in
    jf)      jf --version 2>/dev/null | head -n1 | awk '{print $NF}' ;;
    gh)      gh --version 2>/dev/null | head -n1 | awk '{print $3}' ;;
    docker)  docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' ;;
    jq)      jq --version 2>/dev/null ;;
    openssl) openssl version 2>/dev/null | awk '{print $2}' ;;
    curl)    curl --version 2>/dev/null | head -n1 | awk '{print $2}' ;;
    python3) python3 --version 2>/dev/null | awk '{print $2}' ;;
    *)       echo "installed" ;;
  esac
}

_require_jf_version() {
  local min="$1"
  local have
  have="$(jf --version 2>/dev/null | head -n1 | awk '{print $NF}')"
  [[ -n "$have" ]] || die "cannot parse jf CLI version"
  # dotted-integer compare via sort -V
  if [[ "$(printf '%s\n%s\n' "$min" "$have" | sort -V | head -n1)" != "$min" ]]; then
    die "jf CLI ${have} is older than required ${min}. Upgrade: 'curl -fL https://install-cli.jfrog.io | sh' or 'brew upgrade jfrog-cli'."
  fi
}

_install_hint() {
  local tool="$1"
  local hint=""
  case "$POC_OS:$tool" in
    macos:jf)        hint="brew install jfrog-cli   (or: curl -fL https://install-cli.jfrog.io | sh)" ;;
    macos:gh)        hint="brew install gh   &&   gh auth login" ;;
    macos:docker)    hint="brew install --cask docker   (or download Docker Desktop from docker.com)" ;;
    macos:jq)        hint="brew install jq" ;;
    macos:openssl)   hint="brew install openssl@3   (macOS ships LibreSSL — OpenSSL is preferred)" ;;
    macos:curl)      hint="preinstalled — reinstall Xcode command line tools: xcode-select --install" ;;
    macos:python3)   hint="brew install python@3.12" ;;

    debian:jf)       hint="curl -fL https://install-cli.jfrog.io | sh   (or apt: see https://jfrog.com/getcli/)" ;;
    debian:gh)       hint="curl -sS https://webi.sh/gh | sh   (or follow https://github.com/cli/cli/blob/trunk/docs/install_linux.md)   then: gh auth login" ;;
    debian:docker)   hint="curl -fsSL https://get.docker.com | sh" ;;
    debian:jq)       hint="sudo apt-get update && sudo apt-get install -y jq" ;;
    debian:openssl)  hint="sudo apt-get update && sudo apt-get install -y openssl" ;;
    debian:curl)     hint="sudo apt-get update && sudo apt-get install -y curl" ;;
    debian:python3)  hint="sudo apt-get update && sudo apt-get install -y python3 python3-venv" ;;

    fedora:jf|rhel:jf)     hint="curl -fL https://install-cli.jfrog.io | sh" ;;
    fedora:gh|rhel:gh)     hint="sudo dnf install -y 'dnf-command(config-manager)' && sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo && sudo dnf install -y gh   then: gh auth login" ;;
    fedora:docker|rhel:docker) hint="curl -fsSL https://get.docker.com | sh" ;;
    fedora:jq|rhel:jq)     hint="sudo dnf install -y jq   (RHEL7: sudo yum install -y jq)" ;;
    fedora:openssl|rhel:openssl) hint="sudo dnf install -y openssl" ;;
    fedora:curl|rhel:curl) hint="sudo dnf install -y curl" ;;
    fedora:python3|rhel:python3) hint="sudo dnf install -y python3.12" ;;

    suse:*)     hint="sudo zypper install ${tool}" ;;
    arch:*)     hint="sudo pacman -S ${tool}" ;;

    linux:jf)       hint="curl -fL https://install-cli.jfrog.io | sh" ;;
    linux:gh)       hint="see https://github.com/cli/cli/blob/trunk/docs/install_linux.md   then: gh auth login" ;;
    linux:docker)   hint="curl -fsSL https://get.docker.com | sh" ;;
    linux:*)        hint="install ${tool} using your distribution's package manager" ;;

    unknown:*)      hint="unsupported OS ($(uname -s)) — install ${tool} manually" ;;
    *)              hint="install ${tool} — no specific hint for ${POC_OS}" ;;
  esac
  echo -e "    ${C_YELLOW}fix:${C_RESET} ${hint}"
}

# ---------- JFrog connection verification ------------------------------------
# The first thing every setup script does after preflight is prove that the
# active jf CLI profile can reach JFrog. If `jf rt ping` fails, the script
# stops before doing anything else and prints a multi-step remediation guide.
#
# Call order intended by every script:
#     preflight <tools>            # 1. tools installed?
#     verify_jf_connection         # 2. can we talk to JFrog?  <-- this fn
#     load_env                     # 3. read config
#
# In practice `load_env` calls this automatically after activating the
# profile so callers can just say `load_env`. Scripts that only need
# connectivity (e.g. collision check) can call this directly too.
verify_jf_connection() {
  local profile_id url

  # `jf c show --format=json` prints an ARRAY of all profiles but does NOT
  # mark which is default. The plain-text `jf c show` output does, so we
  # parse the human form to find the active profile ID and cross-reference
  # against the JSON to pull URL/serverId.
  local plain_output
  plain_output="$(jf c show 2>/dev/null || true)"
  if [[ -z "$plain_output" ]]; then
    _reject_jf_connection "" "" "no jf CLI profile is configured"
  fi

  # Extract server-id from the block that has "Default: true".
  profile_id="$(echo "$plain_output" | awk '
      /^Server ID:/{id=$0; sub(/^Server ID:[[:space:]]*/, "", id)}
      /^Default:[[:space:]]*true/{print id; exit}
  ')"
  # If no profile is marked default, fall back to the first Server ID printed.
  if [[ -z "$profile_id" ]]; then
    profile_id="$(echo "$plain_output" | awk '/^Server ID:/{sub(/^Server ID:[[:space:]]*/, ""); print; exit}')"
  fi
  [[ -n "$profile_id" ]] || _reject_jf_connection "" "" "cannot identify an active jf CLI profile"

  # Pull URL for that profile from the JSON output (URL is not sensitive).
  url="$(jf c show --format=json 2>/dev/null \
        | jq -r --arg id "$profile_id" '.[] | select(.serverId==$id) | (.url // .platformUrl // .artifactoryUrl // empty)' \
        | sed 's:/$::' | head -n1)"
  [[ -n "$url" ]] || url="<unknown>"

  log "Verifying JFrog connection (profile='${profile_id}', url=${url})"

  local ping_output
  if ! ping_output="$(jf rt ping 2>&1)"; then
    _reject_jf_connection "$profile_id" "$url" "$ping_output"
  fi

  ok "JFrog connection verified — 'jf rt ping' returned OK on ${profile_id}"
}

# Internal: print the multi-step remediation guide and exit.
_reject_jf_connection() {
  local profile_id="$1" url="$2" reason="$3"
  cat >&2 <<EOF

${C_RED}✗  JFrog connection check failed${C_RESET}

  Command : jf rt ping
  Profile : ${profile_id:-<none>}
  URL     : ${url:-<unknown>}
  Reason  : ${reason}

  This is the first check every setup script runs. Nothing has been
  created on the JFrog side; it is safe to fix and retry.

  Work through the following steps in order — most failures are resolved
  by step 1 or step 3.

  ${C_BOLD}1. Confirm an admin profile is active${C_RESET}

     ${C_BLUE}jf c show${C_RESET}

     If nothing prints, no profile exists. Create one:

     ${C_BLUE}jf c add poc-admin --interactive${C_RESET}
     ${C_BLUE}jf c use poc-admin${C_RESET}

     When prompted, choose "Access Token" authentication and paste an
     Access Token from the JFrog UI (User menu → Edit Profile →
     Identity Tokens → Generate).

  ${C_BOLD}2. Test raw network reachability${C_RESET}

     ${C_BLUE}curl -sSI ${url:-<your-jfrog-url>}/artifactory/api/system/ping${C_RESET}

     If curl fails, the machine cannot reach the tenant (VPN, firewall,
     DNS). Fix the network path before touching JFrog config.
     If curl returns HTTP 200, the network is fine — go to step 3.

  ${C_BOLD}3. Refresh the access token${C_RESET}

     Access tokens expire. In the JFrog UI generate a fresh Identity
     Token, then re-add the profile:

     ${C_BLUE}jf c remove ${profile_id:-<name>}${C_RESET}
     ${C_BLUE}jf c add ${profile_id:-<name>} --interactive${C_RESET}

  ${C_BOLD}4. Confirm the token has the right scope${C_RESET}

     The setup pipeline creates repos, users, groups, gates, and
     integrations. That requires a token from an account with the
     Platform Admin role. Read-only or project-scoped tokens will
     succeed on 'jf rt ping' but fail later on user/repo creation.

  After fixing, re-run this script.

EOF
  exit 1
}

# ---------- env loading ------------------------------------------------------
# Loads the (credential-free) .env, activates the requested jf profile,
# verifies the connection, then derives JF_URL from the profile.
load_env() {
  local env_file="${SETUP_DIR}/.env"
  [[ -f "$env_file" ]] || die "Missing ${env_file}. Copy setup/.env.example and edit it."
  # shellcheck disable=SC1090
  set -a; source "$env_file"; set +a

  : "${POC_APP_NAME:?POC_APP_NAME must be set in setup/.env}"
  validate_app_name "$POC_APP_NAME"

  # Activate the requested profile if one was named; otherwise use whatever is
  # currently active. Fail hard if the named profile does not exist.
  if [[ -n "${JF_CLI_PROFILE:-}" ]]; then
    jf c use "$JF_CLI_PROFILE" >/dev/null 2>&1 \
      || die "Cannot activate jf profile '$JF_CLI_PROFILE'. Run: jf c add $JF_CLI_PROFILE --interactive"
  fi

  # ---- FIRST STEP: prove we can talk to JFrog before doing anything else ----
  verify_jf_connection

  # From here on we trust the profile — derive URL etc. for downstream use.
  # Reuse the same active-profile-id logic as verify_jf_connection.
  local active_id
  active_id="$(jf c show 2>/dev/null | awk '
      /^Server ID:/{id=$0; sub(/^Server ID:[[:space:]]*/, "", id)}
      /^Default:[[:space:]]*true/{print id; exit}
  ')"
  [[ -n "$active_id" ]] || active_id="$(jf c show 2>/dev/null | awk '/^Server ID:/{sub(/^Server ID:[[:space:]]*/, ""); print; exit}')"

  JF_URL="$(jf c show --format=json 2>/dev/null \
            | jq -r --arg id "$active_id" '.[] | select(.serverId==$id) | (.url // .platformUrl // .artifactoryUrl // empty)' \
            | sed 's:/$::' | head -n1)"
  [[ -n "$JF_URL" ]] || die "Active jf profile has no URL configured."

  # Derive Docker registry host (used only in printed instructions, not for auth).
  POC_DOCKER_REGISTRY_HOST="${JF_URL#https://}"
  POC_DOCKER_REGISTRY_HOST="${POC_DOCKER_REGISTRY_HOST#http://}"
  POC_DOCKER_REGISTRY_HOST="${POC_DOCKER_REGISTRY_HOST%%/*}"

  export JF_URL POC_APP_NAME POC_DOCKER_REGISTRY_HOST
}

# ---------- naming helpers ---------------------------------------------------
# All JFrog object keys are produced from these helpers so the naming
# convention is enforced in exactly one place. The convention itself is
# documented in docs/NAMING.md.
#
# Pattern:  <app>-<technology>-<maturity>-<class>            (repositories)
#           <app>-<stage>-<role>                              (permission targets)
#           <app>-<stage>-svc                                 (service users)
#           <app>-<stage>-group                               (groups)
#           <app>-github-<stage>                              (OIDC integrations)
#           <app>-<descriptor>                                (curation policies)
prefix()          { echo "${POC_APP_NAME}-$1"; }
# Remote (upstream-proxying) repos — no maturity segment applies.
repo_pypi()       { prefix "pypi-remote"; }
repo_npm()        { prefix "npm-remote"; }
repo_docker()     { prefix "docker-remote"; }
# Stage-local repos — include technology so multi-tech expansion later
# does not collide (e.g. adding python-dev-local next to docker-dev-local).
repo_stage()      { prefix "docker-$1-local"; }        # <app>-docker-dev-local
# Service identities used by CI (via OIDC). The `-svc` suffix marks these
# as service accounts in Admin UIs.
stage_user()      { prefix "$1-svc"; }                 # <app>-dev-svc
group_stage()     { prefix "$1-group"; }               # <app>-dev-group
# Permission targets — role suffix reads as English: writer / promoter.
perm_target()     { prefix "$1-$2"; }                  # <app>-dev-writer
policy_id()       { prefix "$1"; }
# OIDC integrations — spell out `github` so the Admin UI is unambiguous.
oidc_int()        { prefix "github-$1"; }              # <app>-github-dev

# ---------- name validation --------------------------------------------------
# Application-name rules (also govern the AppTrust application key and every
# prefix produced above):
#   - 3-30 chars total (leaves headroom for the longest suffix, -docker-prod-local = 18)
#   - lowercase alphanumeric + dash
#   - must start and end with alphanumeric
#   - no consecutive dashes
#   - not a JFrog-reserved suffix word
validate_app_name() {
  local n="$1"
  local reserved=(local remote virtual federated group svc dev qa prod docker pypi npm)

  if (( ${#n} < 3 || ${#n} > 30 )); then
    die "POC_APP_NAME '${n}' must be 3-30 chars (got ${#n})."
  fi
  if ! [[ "$n" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]]; then
    die "POC_APP_NAME '${n}' must be lowercase alphanumeric+dash, starting and ending with alphanumeric."
  fi
  if [[ "$n" == *--* ]]; then
    die "POC_APP_NAME '${n}' must not contain consecutive dashes."
  fi
  for r in "${reserved[@]}"; do
    if [[ "$n" == "$r" ]]; then
      die "POC_APP_NAME '${n}' is a JFrog reserved word — pick a distinguishing name."
    fi
  done
}

# ---------- CLI wrappers -----------------------------------------------------
# jf_admin runs a jf command using the active profile and dies on failure.
jf_admin() {
  jf "$@" || die "jf $* failed"
}

# rt_api: authenticated call against the JFrog platform REST API using the
# active jf CLI profile. Used only for endpoints that no `jf` sub-command
# exposes yet — always leave a `# CLI-gap:` comment above the call site.
#
# Implemented via `jf api`, which handles URL, auth token, and header
# assembly using the SAME profile that `jf rt ping` validated. The access
# token is masked in `jf c show` output, so we do not — and cannot — pull
# it out ourselves.
#
#   rt_api METHOD PATH [BODY]
#
# Prints the response body to stdout, HTTP status line to stderr. Non-2xx
# exits with status 1 but still prints the body — same contract as `jf api`.
rt_api() {
  local method="$1" path="$2"
  local body=""
  if [[ $# -ge 3 ]]; then body="$3"; fi

  local args=(api "$path" -X "$method" -H "Content-Type: application/json")
  if [[ -n "$body" ]]; then
    args+=(--data "$body")
  fi
  jf "${args[@]}"
}

# api_status_code: run a GET against a platform path and return only the
# HTTP status code (parsed from `jf api`'s stderr log line).
#
# Sample stderr line format:
#     12:34:56 [Info]  Http Status: 200
#     12:34:56 [Error] Http Status: 404
#
# Prints "000" on connection failure so callers can distinguish that from
# a real HTTP error. Never propagates jf api's non-zero exit.
api_status_code() {
  local path="$1" method="${2:-GET}"
  local stderr
  stderr="$(jf api "$path" -X "$method" 2>&1 >/dev/null || true)"
  local code
  code="$(printf '%s\n' "$stderr" | awk '/Http Status:/{print $NF; exit}')"
  [[ -n "$code" ]] || code="000"
  echo "$code"
}

# rt_api_status: like rt_api but returns only the HTTP status code (as string)
# rather than the response body. Useful for idempotent create/update calls
# where you want to distinguish 200/201 (created) from 409 (already exists)
# without parsing the body.
#
#   rt_api_status METHOD PATH [BODY]  → prints "200"/"201"/"409"/"000"/…
rt_api_status() {
  local method="$1" path="$2"
  local body=""
  if [[ $# -ge 3 ]]; then body="$3"; fi

  local stderr args
  args=(api "$path" -X "$method" -H "Content-Type: application/json")
  [[ -n "$body" ]] && args+=(--data "$body")
  stderr="$(jf "${args[@]}" 2>&1 >/dev/null || true)"
  local code
  code="$(printf '%s\n' "$stderr" | awk '/Http Status:/{print $NF; exit}')"
  [[ -n "$code" ]] || code="000"
  echo "$code"
}

# ---------- object existence probes ------------------------------------------
# Each probe returns 0 (found) / non-zero (not found). Uses `jf rt curl` for
# Artifactory endpoints and `rt_api` for other services; both authenticate
# via the active jf CLI profile.

repo_exists() {
  jf rt curl -sS -o /dev/null -w '%{http_code}' "api/repositories/$1" 2>/dev/null | grep -q '^200$'
}
user_exists() {
  jf rt curl -sS -o /dev/null -w '%{http_code}' "api/security/users/$1" 2>/dev/null | grep -q '^200$'
}
group_exists() {
  jf rt curl -sS -o /dev/null -w '%{http_code}' "api/security/groups/$1" 2>/dev/null | grep -q '^200$'
}
permission_exists() {
  jf rt curl -sS -o /dev/null -w '%{http_code}' "api/v2/security/permissions/$1" 2>/dev/null | grep -q '^200$'
}
oidc_integration_exists() {
  [[ "$(api_status_code "/access/api/v1/oidc/$1")" == "200" ]]
}
apptrust_application_exists() {
  [[ "$(api_status_code "/apptrust/api/v1/applications/$1")" == "200" ]]
}
apptrust_gate_exists() {
  local app="$1" gate_id="$2"
  jf api "/apptrust/api/v1/applications/${app}/gates" 2>/dev/null \
    | jq -e --arg id "$gate_id" '.[] | select(.id == $id)' >/dev/null
}
curation_policy_exists() {
  # CLI-gap: jf curation is not available; use the Xray REST API.
  # Curation policies are stored with a numeric id; we match by name.
  local name="$1"
  jf api "/xray/api/v1/curation/policies?num_of_rows=1000" -X GET 2>/dev/null \
    | jq -e --arg n "$name" 'any(.data[]; .name == $n)' >/dev/null 2>&1
}
evidence_key_exists() {
  [[ "$(api_status_code "/evidence/api/v1/keys/$1")" == "200" ]]
}
