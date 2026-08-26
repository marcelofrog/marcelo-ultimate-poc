# Naming conventions

Every JFrog object this POC creates is derived from a small set of naming
helpers in [`setup/lib/common.sh`](../setup/lib/common.sh). Those helpers
implement JFrog's recommended `<team>-<technology>-<maturity>-<class>`
repository pattern and extend it with a few conventions of our own for
non-repository objects. The rules below are what customers should carry
into their own environments — the shell functions are just the enforcement
mechanism.

## Rule of one prefix

Every object starts with `${POC_APP_NAME}`. That name is validated at load
time (see `validate_app_name` in `common.sh`) with the following rules:

| Rule | Rationale |
|------|-----------|
| 3–30 characters | Leaves ≥ 30 characters for suffixes so the longest key (`<app>-docker-prod-local`) stays comfortably below JFrog's 64-character repo-key limit. |
| Lowercase alphanumeric + dashes | Matches JFrog's platform-wide repo-key charset; avoids URL-encoding surprises. |
| Must start and end with alphanumeric | JFrog rejects leading/trailing dashes on many object types. |
| No consecutive dashes | Cosmetic, but consistent with Debian-style package naming. |
| Not a reserved word | Prevents keys that would collide with the segment vocabulary: `local`, `remote`, `virtual`, `federated`, `group`, `svc`, `dev`, `qa`, `prod`, `docker`, `pypi`, `npm`. |

## Repositories

**Convention:** `<team>-<technology>-<maturity>-<class>`.

For remote (upstream-proxying) repositories the maturity segment is omitted
because upstream registries are not maturity-scoped.

| Purpose | Helper | Example (with `POC_APP_NAME=ultimate-demo`) |
|---------|--------|--------|
| Curated PyPI proxy   | `repo_pypi`   | `ultimate-demo-pypi-remote` |
| Curated npm proxy    | `repo_npm`    | `ultimate-demo-npm-remote` |
| Curated Docker proxy | `repo_docker` | `ultimate-demo-docker-remote` |
| Stage local Docker (dev)  | `repo_stage dev`  | `ultimate-demo-docker-dev-local` |
| Stage local Docker (qa)   | `repo_stage qa`   | `ultimate-demo-docker-qa-local` |
| Stage local Docker (prod) | `repo_stage prod` | `ultimate-demo-docker-prod-local` |

Including the `docker` segment makes it obvious *why* multiple stage repos
exist and reserves space for adding technology-specific stage repos later
(`<app>-python-dev-local`, `<app>-npm-dev-local`, …) without collisions.

## Service users

**Convention:** `<app>-<stage>-svc`.

| Helper | Example | Purpose |
|--------|---------|---------|
| `stage_user dev`  | `ultimate-demo-dev-svc`  | GitHub Actions build identity |
| `stage_user qa`   | `ultimate-demo-qa-svc`   | GitHub Actions qa-promotion identity |
| `stage_user prod` | `ultimate-demo-prod-svc` | GitHub Actions prod-promotion identity |

The `-svc` suffix marks these as service accounts. This is important because
Artifactory admins routinely filter user lists for `svc` to identify
non-human accounts during audits and OIDC reviews.

Password login is disabled on every service user at create time
(`internalPasswordDisabled: true`, `disableUIAccess: true`). Authentication
happens exclusively via OIDC-issued short-lived tokens.

## Groups

**Convention:** `<app>-<stage>-group`.

| Helper | Example |
|--------|---------|
| `group_stage dev`  | `ultimate-demo-dev-group` |
| `group_stage qa`   | `ultimate-demo-qa-group` |
| `group_stage prod` | `ultimate-demo-prod-group` |

The trailing `-group` may look redundant, but Artifactory's search UI does
not visually distinguish groups from users, so a keyword suffix is standard
practice in shops that manage more than a handful of RBAC objects.

## Permission targets

**Convention:** `<app>-<stage>-<role>`. Roles are English words:

- `writer` — the identity can push to and modify the named repo
- `promoter` — the identity can read *from* the named repo and promote *out of* it

| Helper | Example | Meaning |
|--------|---------|---------|
| `perm_target dev writer`    | `ultimate-demo-dev-writer`    | dev group writes into dev repo |
| `perm_target qa promoter`   | `ultimate-demo-qa-promoter`   | qa group reads dev repo, promotes to qa |
| `perm_target qa writer`     | `ultimate-demo-qa-writer`     | qa group writes into qa repo |
| `perm_target prod promoter` | `ultimate-demo-prod-promoter` | prod group reads qa repo, promotes to prod |
| `perm_target prod writer`   | `ultimate-demo-prod-writer`   | prod group writes into prod repo |

Reading a permission target as English (`ultimate-demo-qa-promoter`
= "ultimate-demo's qa promoter role") avoids the `pt-` abbreviation that
we've seen confuse first-time reviewers.

## OIDC integrations

**Convention:** `<app>-github-<stage>`.

| Helper | Example |
|--------|---------|
| `oidc_int dev`  | `ultimate-demo-github-dev` |
| `oidc_int qa`   | `ultimate-demo-github-qa` |
| `oidc_int prod` | `ultimate-demo-github-prod` |

Spelling out `github` (rather than `gh`) matches other JFrog OIDC integration
examples in the docs and reduces friction for shops that add non-GitHub
providers alongside (`<app>-gitlab-dev`, `<app>-buildkite-dev`, …).

## Curation policies

**Convention:** `<app>-<descriptor>`. Descriptors are the human name of the
policy rule.

| Example | Rule |
|---------|------|
| `ultimate-demo-curation-malicious`  | Block malicious packages |
| `ultimate-demo-curation-no-license` | Block packages without a declared license |
| `ultimate-demo-curation-immature`   | Block packages published < 7 days ago |

## Signing key alias

**Convention:** `<app>-evd-key`. Matches JFrog's own `evd` abbreviation for
Evidence throughout the CLI (`jf evd create`, `--key-alias`).

## AppTrust application

**Convention:** the application key is exactly `${POC_APP_NAME}`. No
suffix, no prefix — the application key *is* the team/project identity that
all the other objects hang off of.

## Extending the convention

When you add a new object type to this POC, ask yourself these three
questions in order:

1. **Does it live in a JFrog repository?** Use `<app>-<tech>-<maturity>-<class>`.
2. **Is it a role/permission?** Use `<app>-<stage>-<role>` where the role is
   an English word (`writer`, `promoter`, `reader`, `admin`).
3. **Is it a service identity?** Use `<app>-<stage>-svc`.

If your new object doesn't fit any of those, add a helper to
`setup/lib/common.sh` alongside `perm_target`/`stage_user`/`oidc_int` and
document it in this file — a naming convention that lives only in shell
scripts drifts within a quarter.
