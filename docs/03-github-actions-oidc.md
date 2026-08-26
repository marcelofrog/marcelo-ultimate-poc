# 3. GitHub Actions & OIDC

The core RBAC boundary in this POC is enforced by **three separate JFrog OIDC integrations**, one per lifecycle stage, each accepting tokens only from a specific GitHub Environment. Nothing else the CI could do can break the boundary:

- Long-lived secrets? None exist to steal — GitHub Actions holds no JFrog credentials, and the three stage service users have internal password login disabled from the moment they are created (`internalPasswordDisabled: true`).
- Rewrite the workflow? A `dev` environment can't request `qa`-scoped OIDC tokens; GitHub itself won't issue them.
- Compromise a JFrog identity directly? Even if the `<app>-dev-svc` user were compromised, it has no permissions on the qa or prod repos — the RBAC boundary is enforced by the permission targets, not by identity secrecy.

## Token flow

```
┌─────────────────────────────────────────────────────────────────────┐
│  GitHub Actions runner                                              │
│  workflow: promote-dev-to-qa.yml                                    │
│  job.environment: qa   ────────────────────────────────────┐        │
└────────────────────────────────────────────────────────────┼────────┘
                                                              │
                       ① GitHub mints an OIDC JWT with claims:│
                          repository = <owner>/<repo>          │
                          environment = qa                     │
                          ref = refs/heads/main                │
                                                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  jfrog/setup-jfrog-cli@v4  → POST /access/api/v1/oidc/token         │
│  audience = jfrog-<app>                                             │
│  provider = <app>-github-qa   ← must match integration name         │
└────────────────────────────────────────────────────────────┬────────┘
                                                              │
                       ② JFrog Access validates JWT signature │
                          against GitHub's JWKS, then walks    │
                          the integration's identity mappings. │
                                                              │
                       Only the qa integration's mapping has   │
                       `environment: qa` in its claim spec.    │
                                                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Access issues an internal token as user  <app>-qa-svc              │
│  scope  applied-permissions/groups:<app>-qa-group                   │
│  ttl    3600 seconds                                                │
└─────────────────────────────────────────────────────────────────────┘
```

If step ① happens in the `dev` environment, GitHub embeds `environment=dev` in the JWT. Step ②'s only mapping requires `environment=qa`. The token request fails — job errors before any promote call runs.

## What you configure in GitHub

| Level | Name | Type | Value |
|-------|------|------|-------|
| Repo | `JF_URL`             | Variable | Your JFrog base URL |
| Repo | `JF_DOCKER_REGISTRY` | Variable | Same host, no scheme |
| Repo | `POC_APP_NAME`       | Variable | Whatever you passed in `.env` |
| Env `dev`  | `JF_OIDC_PROVIDER` | Variable | `${APP}-github-dev` |
| Env `qa`   | `JF_OIDC_PROVIDER` | Variable | `${APP}-github-qa` |
| Env `prod` | `JF_OIDC_PROVIDER` | Variable | `${APP}-github-prod` |
| Env `qa`   | required reviewers | Setting  | at least one human |
| Env `prod` | required reviewers | Setting  | at least one human |

Zero secrets. If your GitHub Environments panel shows any repository secrets, they are not needed for this POC.

## Workflow to environment mapping

| Workflow | GitHub Environment | OIDC integration | JFrog user | Can write to |
|----------|--------------------|------------------|------------|--------------|
| `build.yml`                | `dev`  | `${APP}-github-dev`  | `${APP}-dev-svc`  | `${APP}-docker-dev-local` |
| `promote-dev-to-qa.yml`    | `qa`   | `${APP}-github-qa`   | `${APP}-qa-svc`   | `${APP}-docker-qa-local`, promote from dev |
| `promote-qa-to-prod.yml`   | `prod` | `${APP}-github-prod` | `${APP}-prod-svc` | `${APP}-docker-prod-local`, promote from qa |

If you copy `build.yml` and change `environment: dev` to `environment: prod`, the job stops the first time it tries to `jf rt ping` — GitHub emits a prod-scoped JWT, JFrog swaps it for a token bound to `<app>-prod-svc`, and that identity has zero write permissions on any dev-stage repo. The build step fails immediately.

## `jfrog/setup-jfrog-cli@v4`

This official action does two things:
1. Requests a GitHub OIDC token with the audience you specify (`jfrog-<app>`).
2. Exchanges it against `$JF_URL` for a short-lived Access token, then writes a `jf` CLI profile using that token.

Every subsequent `jf` invocation in the job uses that profile — no `--user` / `--password` flag ever exists.

Continue to [04-promotion-flow.md](04-promotion-flow.md).
