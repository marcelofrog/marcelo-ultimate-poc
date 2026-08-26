# 5. Recommendations & known gaps

This document is the output of a deep review of the POC. It calls out things that are intentionally simplified, real gaps against a production-grade rollout, and concrete extensions that make good "day-two" talking points during customer conversations.

Grouped by area, most impactful first.

## A. Evidence & attestation

### A1. Publish an SBOM alongside the existing signed predicates
**Status:** not implemented, high value.
The build workflow already produces three signed evidence attestations (test results, docker image, provenance) and each promotion produces a fourth. Adding an SBOM predicate is a single extra step using the same key, and is a *very* common ask from security teams evaluating AppTrust.

```yaml
- run: jf docker scan "${{ steps.tag.outputs.image }}" --format=cyclonedx --output=evidence/sbom.cdx.json
- run: |
    jf evd create \
      --predicate           evidence/sbom.cdx.json \
      --predicate-type      "https://cyclonedx.org/schema/sbom-v1.5" \
      --application-key     "${APP_NAME}" \
      --application-version "${{ steps.tag.outputs.app_version }}" \
      --key-alias           poc-signing-key
```

Update the Rego gate (or add a second one) to require SBOM presence.

### A2. ~~Add SLSA build provenance~~ (done)
The build workflow publishes an `https://slsa.dev/provenance/v1` predicate against every application version, signed with the same key. The predicate carries the git URI+SHA, the workflow file path, actor, run id, and both source-code and image materials.

### A3. Sign the container image with cosign, verify at promote time
The build workflow already attaches a signed docker-image evidence attestation at both the application-version and manifest-artifact level, using the same ed25519 key that signs test results and provenance. Cosign is a complementary layer: it embeds the signature in the OCI registry directly, so external consumers (kubelet admission controllers, third-party scanners) can verify without hitting the JFrog Evidence API. Add a `cosign sign --key env://COSIGN_KEY` step after `jf docker push` and a `cosign verify` step at the head of each promotion workflow.

## B. Xray & Curation

### B1. Wire a continuous Xray Watch on each stage repository
The security promotion gate fires on promotion, but ongoing Xray watches with policies mapped to the same CVSS threshold give you *between-promotion* alerting. Add a step to `03-setup-apptrust.sh` that creates one watch per stage repo, each pointing at the security policy.

### B2. Enable Curation waivers demo path
The policies are already `waiver_requestable: true`. Add a fourth setup script (`05-configure-curation-notifications.sh`) that wires an email or Slack notification target so the "developer requests waiver, security approves" flow can be shown in the UI without additional config.

### B3. Sub-thresholds and applicability drill-down
Consider a second promotion gate for CVSS 7.0–8.9 that only *warns* instead of blocks — customers frequently want a tiered gate.

## C. GitHub Actions

### C1. Shift-left the Curation audit onto PRs
Currently `build.yml` runs on push to main only. A tiny sibling workflow that runs `jf curation-audit` on every PR (no docker build, no push) shows dev-loop-friendly Curation without any RBAC concerns.

### C2. Multi-arch builds
The Dockerfile builds `linux/amd64` only. Real production usually wants amd64+arm64. `docker buildx build --platform linux/amd64,linux/arm64` is a one-line change but demos better.

### C3. Docker layer + pip cache
Nothing in the workflow uses `actions/cache`. Adding cache steps drops build time from ~4 minutes to ~40 seconds and is a real ask for large customer repos.

### C4. Version scheme with a real tag
Application versions are currently `1.0.<run_number>-<run_id>`. Customers typically want git tags (`v1.2.3`) to drive the AppTrust version. `workflow_dispatch` with a version input, or a "release" trigger, would move this closer to real usage.

### C5. Bidirectional job outputs between build and promote
Today, a human copies the version string from the build summary and pastes it into the promotion input. A follow-up workflow triggered by `workflow_run` (or a job that stores the version as a repo dispatch payload) would remove the copy-paste and better demonstrate the AppTrust API.

## D. RBAC & OIDC

### D1. Add a "release manager" identity that CAN'T write, only promote
Today the qa and prod identities can both write to their own stage repos. In many customer models, promotion is done by a separate release-management persona whose only privilege is `promote`. Adding a fourth OIDC integration and permission target makes the separation explicit.

### D2. Constrain OIDC on `ref` as well as `environment`
Identity mappings currently key off `repository` and `environment`. Adding `ref = refs/heads/main` (for build) and `ref_type = tag` (for promote) tightens the JWT check.

### D3. ~~Rotate the seeded passwords~~ (done)
`02-setup-users.sh` already generates an ephemeral in-memory password purely
to satisfy the create-user API, then immediately disables internal password
login (`internalPasswordDisabled: true`). Nothing subsequently authenticates
with a password. Kept here as a talking point for customer questions about
credential lifecycle.

## E. Application

### E1. Use `uv` or `pip-tools` for a real lockfile
`requirements.txt` is version-pinned but not hash-pinned. `pip install --require-hashes` combined with a `requirements.lock` generated by `uv pip compile` is materially stronger and, when paired with Curation, closes the "compromised mirror" attack window.

### E2. Add a JavaScript / TypeScript component
The npm curated remote is created but unused. A tiny React health-check page (or even a Node CLI test suite) exercises the npm side of Curation and demonstrates polyglot AppTrust.

### E3. Add an intentionally-vulnerable branch for demoing gate failure
A `demo/failing-cve` branch that pins an old vulnerable version of `requests` and a `demo/failing-tests` branch that comments out three tests give presenters guaranteed-red demos on hand.

## F. Operations

### F1. Automated teardown between demo sessions
`99-teardown.sh` is comprehensive (deletes all 27 tracked objects, supports `--dry-run`, `--yes`, and optional `--purge-{builds,local-keys,github-secret}` flags), but still requires human invocation. A scheduled GitHub Actions job that runs `99-teardown.sh --yes` followed by `00-run-all.sh` nightly would reset a shared POC tenant automatically.

### F2. Rollback story
There is no documented rollback path. AppTrust supports demoting a version by re-promoting an older version; add a `promote-prod-rollback.yml` that takes a previous version and re-promotes it to prod, subject to the same gates.

### F3. Observability
Add a step that publishes build metadata (image digest, gate results) to the JFrog Insight dashboard or to a downstream observability system. Customers often ask "how do we see this in one pane of glass?"

---

## Things NOT to add

Some things look like gaps but are deliberately absent:

- **A full Terraform module for the setup.** The setup scripts are meant to be *readable* — one-liner Terraform equivalents hide the JFrog concepts they teach. If a customer wants IaC, port to Terraform *after* they've seen the shell-script flow.
- **A production-grade FastAPI app.** The endpoints exist to be built and tested, not to be studied.
- **Slack/PagerDuty/Jira integrations.** They add moving parts that break during demos. Leave the notification wiring for post-POC engagement.
