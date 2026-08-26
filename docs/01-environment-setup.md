# 1. Environment setup

Everything under `setup/` is designed to be run once, in order, from your laptop while you hold an admin token on the target JFrog instance. Each script is idempotent — re-running is safe.

```
setup/
├── 00-run-all.sh              ← orchestrator, runs everything below in order
├── 00-check-collisions.sh     ← read-only preflight against JFrog
├── 01-setup-curation.sh       ← curated remotes + blocking policies
├── 02-setup-users.sh          ← dev/qa/prod users + groups
├── 03-setup-apptrust.sh       ← app + stage repos + permissions + gates
├── 03a-setup-signing-key.sh   ← generate ed25519 key + push to GitHub
├── 04-setup-oidc.sh           ← three OIDC integrations for GitHub
├── 99-teardown.sh             ← delete everything (with --dry-run + safety flags)
└── policies/                  ← curation-policy JSON payloads
```

## Step 0 — Collision check (`00-check-collisions.sh`)

Runs first. Enumerates all 27 JFrog objects the pipeline would create,
probes the instance for each, and prints a matrix like:

```
  KIND                NAME                                           STATUS
  ----                ----                                           ------
  repo (remote)       ultimate-demo-pypi-remote                      free
  repo (local)        ultimate-demo-docker-dev-local                 EXISTS
  user (svc)          ultimate-demo-dev-svc                          free
  ...
```

- If everything is `free`, the pipeline continues.
- If anything shows `EXISTS`, the check stops with three options: change `POC_APP_NAME`, run `99-teardown.sh`, or re-run with `--reuse-existing` (idempotent child scripts will then skip the objects that already exist).

This step is read-only — nothing on the JFrog side gets mutated until it passes.

## Order matters

```
Curation ─► Users ─► AppTrust ─► OIDC
```

- Curation must exist before AppTrust, because AppTrust references the stage-local repos and those need curated remotes upstream in the resolution order.
- Users must exist before AppTrust, because AppTrust attaches per-stage permission targets to the stage groups.
- OIDC runs last, because it needs the users and the AppTrust application already in place.

## Step 1 — Curation (`01-setup-curation.sh`)

Creates:

| Object | Kind | Notes |
|--------|------|-------|
| `${APP}-pypi-remote`   | Remote, PyPI            | `curated: true`, Xray indexing on |
| `${APP}-npm-remote`    | Remote, npm             | present for future use |
| `${APP}-docker-remote` | Remote, Docker Hub      | pulled by the Dockerfile |
| `${APP}-curation-malicious`   | Curation policy | blocks any package flagged malicious |
| `${APP}-curation-no-license`  | Curation policy | blocks packages missing a license |
| `${APP}-curation-immature`    | Curation policy | blocks packages < 7 days old |

Waiver-requestable is on — participants can walk through the "developer requests waiver, security admin approves" flow in the UI without wiping the policy.

## Step 2 — Users (`02-setup-users.sh`)

Creates three groups and three service users:

| User | Group | Later permissions |
|------|-------|-------------------|
| `${APP}-dev-svc`  | `${APP}-dev-group`  | write on `${APP}-docker-dev-local` |
| `${APP}-qa-svc`   | `${APP}-qa-group`   | read+promote on `${APP}-docker-dev-local`; write on `${APP}-docker-qa-local` |
| `${APP}-prod-svc` | `${APP}-prod-group` | read+promote on `${APP}-docker-qa-local`; write on `${APP}-docker-prod-local` |

Passwords are never sourced from `.env` and never surfaced to the user. `02-setup-users.sh` generates a random value in memory purely to satisfy the create-user API, immediately sets `internalPasswordDisabled: true` and `disableUIAccess: true` on the same call, then throws the value away. From the moment each user exists, the only way to authenticate as that identity is via the OIDC integration wired in `04-setup-oidc.sh`.

## Step 3 — AppTrust (`03-setup-apptrust.sh`)

The heart of the POC. Creates:

1. **Stage repositories** — `${APP}-docker-dev-local`, `${APP}-docker-qa-local`, `${APP}-docker-prod-local` (all Docker V2, all indexed by Xray). The naming follows JFrog's `<team>-<technology>-<maturity>-<class>` convention; see [NAMING.md](NAMING.md).
2. **AppTrust application** — `${APP}` with lifecycle `dev → qa → prod`, bound to the three repos.
3. **Permission targets** — five targets that produce the RBAC matrix in the previous section.
4. **Promotion gates:**
   - **Security gate** — `criteria.cvss_score_min = 9.0`, `applicability = ["applicable"]`, `action = block`. Only CVEs that Xray Contextual Analysis flags as reachable will block promotion. Non-applicable criticals are surfaced but don't block, which matches how real security teams operate.
   - **Rego gate** — evaluates [policies/test-count.rego](../policies/test-count.rego) with `min_passing_tests = ${POC_MIN_PASSING_TESTS}`. Requires an evidence attestation of predicate type `https://jfrog.com/evidence/test-results/v1` with at least the configured number of passing tests and zero failures.

Both gates apply to every stage transition of this application.

## Step 4 — OIDC (`04-setup-oidc.sh <owner/repo>`)

Creates three OIDC integrations, each with a single identity mapping keyed off the GitHub Actions `environment` claim:

| Integration | Matches claims | Issues token as |
|-------------|----------------|-----------------|
| `${APP}-github-dev`  | `repository=<owner/repo>` **and** `environment=dev`  | `${APP}-dev-svc` |
| `${APP}-github-qa`   | `repository=<owner/repo>` **and** `environment=qa`   | `${APP}-qa-svc` |
| `${APP}-github-prod` | `repository=<owner/repo>` **and** `environment=prod` | `${APP}-prod-svc` |

This is the linchpin of the RBAC story. A workflow running in the `dev` environment presents a JWT whose `environment` claim is `dev`; only the dev integration accepts it, and it only maps to the dev user. There is no combination of workflow inputs, secrets, or job configuration that lets the dev job impersonate qa or prod.

The script prints the exact GitHub configuration you must do in the Web UI:

- Create three environments (`dev`, `qa`, `prod`)
- Add required reviewers to `qa` and `prod`
- Set `JF_OIDC_PROVIDER` per environment (the integration name)
- Set `JF_URL`, `JF_DOCKER_REGISTRY`, `POC_APP_NAME` as repo-level variables

## Verifying

The three stage service users are created with **internal password login
disabled** (`02-setup-users.sh` sets `internalPasswordDisabled: true`).
They cannot be logged into with `jf c add --user --password` — by design.

Two ways to verify the RBAC boundary without needing any credential:

**Option A — inspect via the admin profile.** As the admin, read the
effective permissions for each stage user and confirm the matrix:

```bash
for stage in dev qa prod; do
  echo "== ${POC_APP_NAME}-${stage}-svc =="
  jf rt curl -sS "api/security/users/${POC_APP_NAME}-${stage}-svc" \
    | jq '{groups, admin, disableUIAccess, internalPasswordDisabled}'
done
```

**Option B — end-to-end via the workflow.** Push a commit. Watch the
`build` workflow succeed against `dev-local`, then temporarily change
`environment: dev` to `environment: qa` in a branch copy of `build.yml`
and push. The build fails during `jf rt ping` because the qa OIDC
identity has no write access on `dev-local` — proving the boundary
end-to-end using the same auth path production would use.

If Option A shows a dev user with any group other than `${POC_APP_NAME}-dev-group`,
or Option B does not fail as expected, re-run `03-setup-apptrust.sh`
and check the output for permission-target errors.

## Teardown (`99-teardown.sh`)

Removes every JFrog object the setup pipeline created under the current
`POC_APP_NAME` prefix. Intended for tearing demos down between customer
sessions or resetting between iterations.

**Deletion order** is dependency-safe:

```
1. AppTrust application versions
2. AppTrust promotion gates
3. AppTrust application
4. Permission targets            (must go before groups/users)
5. OIDC integrations
6. Curation policies
7. Local stage repositories      (dev/qa/prod docker-locals)
8. Curated remote repositories   (pypi / npm / docker)
9. Service users                 (must go before groups)
10. Groups
11. Evidence signing key
```

**Flags:**

| Flag | Effect |
|------|--------|
| `--dry-run`              | Print the plan; don't call any DELETE. Safe to run without confirmation. |
| `--yes` / `-y`           | Skip the interactive "type the app name" prompt (for CI use). |
| `--purge-builds`         | Also delete build-info records under the application name. |
| `--purge-local-keys`     | Also delete `evidence/keys/` on your workstation. |
| `--purge-github-secret`  | Also delete `POC_EVD_SIGNING_KEY` + `POC_EVD_KEY_ALIAS` from the GitHub repo in `.env`. Requires `gh auth login`. |

**Reporting:** every object prints one of `deleted`, `absent`, or `ERROR`.
A missing object is not a failure — the script tolerates half-applied
previous runs. The exit code is non-zero only if a DELETE actually errored.

**Example — safe preview:**

```bash
./99-teardown.sh --dry-run
```

**Example — full nuke including local key and GitHub secret:**

```bash
./99-teardown.sh --yes --purge-builds --purge-local-keys --purge-github-secret
```

Continue to [02-application-overview.md](02-application-overview.md).
