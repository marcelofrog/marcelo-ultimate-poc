# 0. Prerequisites

Before you run any script in `setup/`, make sure you have the following in place.

## Tooling on your workstation

| Tool | Minimum version | Install |
|------|-----------------|---------|
| JFrog CLI (`jf`) | 2.60 | `brew install jfrog-cli` or `curl -fL https://install-cli.jfrog.io \| sh` |
| GitHub CLI (`gh`), authenticated with `gh auth login` | 2.40 | `brew install gh` — required so the setup can push the generated signing key as a GitHub Actions secret without you touching it. |
| Docker | 24 | Docker Desktop or Rancher Desktop |
| `jq` | 1.6 | `brew install jq` |
| `openssl` | any | preinstalled on macOS/Linux — used to generate the ed25519 evidence signing key |
| Python | 3.12 | pyenv, brew, or system |

You do not have to install these manually before you know they're missing.
Every setup script runs a **preflight check** at start-up that verifies each
tool it needs is on `$PATH` and, if not, exits with an install hint tailored
to your OS (macOS Homebrew, Debian apt, Fedora/RHEL dnf, SUSE zypper, or
Arch pacman). Sample output when Docker is missing on Debian:

```
!  missing required tool: docker
    fix: curl -fsSL https://get.docker.com | sh
✗  1 required tool(s) missing. Install the tool(s) above and re-run.
```

The check also enforces `jf` ≥ 2.60 and, when `gh` is required, confirms
that `gh auth login` has completed. This means running the setup on a
fresh machine gives you a checklist of exactly what to install before
anything touches your JFrog tenant.

## JFrog side

- A JFrog Platform instance (SaaS or self-hosted) with the **Ultimate** subscription.
- **Administrator** account for the initial setup (creating users, repositories, policies, OIDC integrations, AppTrust apps).
- The following JFrog services enabled in your tenant:
  - Artifactory
  - Xray (with **Contextual Analysis** enabled)
  - **Curation Service**
  - **AppTrust**
  - **Evidence Service**
- Outbound internet access from Artifactory to pypi.org, registry.npmjs.org, and registry.hub.docker.com (the curated remotes will proxy these).

## GitHub side

- A repository where you'll push this code. Fork or copy this repo into your GitHub org.
- Admin rights on that repository (you'll create GitHub Environments and configure OIDC).
- Actions enabled.

## Credentials — the ONE step you actually do yourself

Every JFrog credential this POC uses is stored inside the local `jf` CLI
profile you create right now. **Nothing else — no `.env` variable, no
GitHub secret, no shell export — carries a JFrog password or token.**

```bash
jf c add poc-admin --interactive
# When prompted:
#   Server URL:       https://YOUR-TENANT.jfrog.io
#   Authentication:   Access Token
#   Access token:     <paste the admin access token from the Web UI>
jf c use poc-admin
```

That's it. Every setup script and every helper in `setup/lib/common.sh`
resolves the URL, the token, and everything else from this profile.
There is no configuration item asking you for a token, and if you try
to smuggle one in via env var it will be ignored.

## Non-credential config

The setup scripts read one file, `setup/.env`, which you copy from the
template on first run. It contains *no* secrets:

```bash
cp setup/.env.example setup/.env
$EDITOR setup/.env
```

Fields:

| Variable | Meaning |
|----------|---------|
| `JF_CLI_PROFILE` | (optional) name of the `jf c` profile to activate. If empty, whichever profile is currently active is used. |
| `POC_APP_NAME` | AppTrust application name — also used as prefix for every JFrog object |
| `POC_GITHUB_REPO` | `owner/repo` string used when wiring OIDC |
| `POC_MIN_PASSING_TESTS` | Rego gate threshold |
| `POC_CVE_BLOCK_THRESHOLD` | Security gate CVSS floor |

## Confirm CLI access

```bash
jf rt ping         # should return "OK"
jf --version       # should be ≥ 2.60
```

If `jf rt ping` fails, fix the CLI profile before proceeding — every
subsequent script derives its authentication from it.

Once all of the above is green, continue to [01-environment-setup.md](01-environment-setup.md).
