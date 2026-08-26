# 4. Promotion flow & gates

The promotion story is where AppTrust earns its keep. Everything below runs on a real customer instance without additional configuration once setup/00-run-all.sh has completed.

## End-to-end

```
push to main
    │
    ▼
build.yml (env: dev)  ─────────────────────────────────┐
    curation-audit               fail? job red         │
    docker build & push          ⇒ dev-local           │
    apptrust app version         ⇒ stage: dev          │
    pytest → evidence            ⇒ signed predicate #1 │
    docker manifest → evidence   ⇒ signed predicate #2 │
    SLSA provenance → evidence   ⇒ signed predicate #3 │
    (identity: <app>-dev-svc; key = POC_EVD_SIGNING_KEY)     │
                                                       │
    ↓ human clicks "Run workflow"                      │
    │  copy the app_version from build summary         │
promote-dev-to-qa.yml (env: qa, approval required)     │
    identity: <app>-qa-svc                                   │
    call: jf apptrust application-version-promote      │
          --source-stage dev --target-stage qa         │
          --wait-for-gates                             │
                                                       │
      JFrog evaluates BOTH gates:                      │
        ✓ security: no applicable CVE ≥ 9.0            │
        ✓ rego: ≥ N passing tests in evidence          │
      Gates pass → image copied dev-local → qa-local   │
      Gates fail → CLI returns non-zero → job red      │
      On success: signed "promotion" evidence attached │
      to the app version (same signing key)            │
                                                       │
    ↓ human clicks "Run workflow"                      │
promote-qa-to-prod.yml (env: prod, approval required)  │
    identity: <app>-prod-svc                                 │
    same promote call, source qa target prod           │
    same gates re-evaluated                            │
    (Xray may find new CVEs in the meantime — the      │
     gate re-runs against current data.)               │
    On success: signed "promotion" evidence attached   │
                                                       │
    ↓                                                  │
prod-local now holds an immutable copy of the image ───┘
```

## What triggers a gate failure

### Security gate — CVE ≥ 9 (applicable)

Xray Contextual Analysis walks the image, identifies vulnerable components, then tries to determine whether the vulnerable code path is actually reachable in the built artifact. Only **applicable** findings above the CVSS floor block promotion.

Try this in the POC:
1. Downgrade `requests` to a version that has an applicable high CVE.
2. Push. `build.yml` succeeds — dev is a lax stage.
3. Trigger `promote-dev-to-qa`. It fails on the gate; you get the exact CVE(s) in the CLI output.
4. Upgrade `requests`, rebuild, retry promote. Gate passes.

### Rego gate — test count

The Rego policy in [policies/test-count.rego](../policies/test-count.rego) reads the evidence predicate attached to the version. If:
- no `test-results` evidence is attached, or
- total passing tests < `POC_MIN_PASSING_TESTS`, or
- any evidence reports `failed > 0`

the gate denies with a human-readable reason.

Try this in the POC:
1. Delete two tests from `app/tests/test_main.py` (drop below the threshold).
2. Push. `build.yml` succeeds but the emitted predicate says `passed: 3` (or less).
3. Trigger `promote-dev-to-qa`. Gate denies with `only 3 passing tests, need at least 5`.

## Why the same gate blocks qa→prod as well

`--wait-for-gates` re-evaluates all applicable gates at each promotion. Between dev→qa and qa→prod:

- New CVEs may have been published, or Xray may have updated its applicability data.
- The evidence attestation is still bound to that immutable application version, so the Rego check stays deterministic.

You get "new information will block old artifacts" for free — the classic AppTrust value prop.

## Where results show up

- **GitHub Actions run** — CLI output on the promote step includes the gate verdict.
- **JFrog UI → AppTrust → Applications → `${APP}`** — every version shows attached evidence and per-stage gate history.
- **JFrog UI → Xray → Watches** — the security gate references watches auto-generated per application; you can drill from a blocked promotion into the exact CVE that failed.

Continue to [RECOMMENDATIONS.md](RECOMMENDATIONS.md) for gaps and enhancement ideas.
