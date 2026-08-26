# 2. Application walkthrough

The sample application is intentionally tiny. It has three responsibilities:

1. Import a handful of packages that Curation policies find interesting.
2. Build into a Docker image whose base layer *and* Python wheels come from JFrog curated remotes.
3. Provide a pytest suite whose results seed the Evidence attestation that the promotion Rego gate reads.

## Runtime code

- [`app/main.py`](../app/main.py) — three endpoints: `/health`, `/echo`, `/outbound-check`.
- [`app/requirements.txt`](../app/requirements.txt) — pinned runtime dependencies. Every entry has a real-world supply-chain incident on its history (typo-squats on `requests`, malicious mirrors of `httpx`, wormed versions of `pydantic-core`, etc.). Perfect fodder for Curation demos.
- [`app/requirements-dev.txt`](../app/requirements-dev.txt) — pytest + pytest-json-report for producing the evidence predicate.

## The Dockerfile

```dockerfile
ARG JF_DOCKER_REGISTRY
ARG JF_DOCKER_REMOTE
FROM ${JF_DOCKER_REGISTRY}/${JF_DOCKER_REMOTE}/library/python:3.12-slim
```

Two things worth noting:

1. **Base image comes through JFrog.** Docker Hub is never contacted directly. Curation policies fire on the base layer just as they do on wheels.
2. **PyPI index is overridden.** The `pip install` step uses `--index-url` pointing at the curated PyPI remote, so pip cannot escape to pypi.org even if a transitive dep tries to.

Both are enforced at CI time by `build.yml` — the workflow supplies the build-args and rejects if a wheel would come from anywhere but the curated remote.

## Tests and signed evidence

Every build produces **three signed Evidence attestations** against the same AppTrust application version, plus a fourth one at the artifact (docker manifest) level. All four are signed with the ed25519 key that `setup/03a-setup-signing-key.sh` provisioned — one key, one chain of custody.

| Predicate type | Attached to | Predicate content |
|----------------|-------------|-------------------|
| `https://jfrog.com/evidence/test-results/v1` | app version | pytest pass/fail/skip counts (feeds the Rego promotion gate) |
| `https://jfrog.com/evidence/artifact/v1`     | app version + docker manifest | image tag, immutable digest, base image, builder |
| `https://slsa.dev/provenance/v1`             | app version | SLSA-style build provenance (git URI+SHA, workflow file, actor, materials) |

Each subsequent promotion (`dev→qa`, `qa→prod`) publishes a fifth predicate type, `https://jfrog.com/evidence/promotion/v1`, signed with the same key. That means a prod-stage application version carries a fully verifiable timeline: what was built, from what source, by which tests, and who moved it forward.

`pytest.ini` emits the JSON report the test-results predicate is built from:

```
addopts = -ra --json-report --json-report-file=../evidence/pytest-report.json
```

If you add tests, the passing count grows — good news for the Rego gate. If you delete tests below `POC_MIN_PASSING_TESTS`, dev→qa promotion fails deterministically. That is the demo.

## Running locally (optional)

Nothing about the POC requires local runs, but if you want to sanity-check the app before pushing:

```bash
cd app
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
pytest
uvicorn main:app --reload
```

`curl http://127.0.0.1:8000/health` should return a JSON blob with `status: ok`.

Continue to [03-github-actions-oidc.md](03-github-actions-oidc.md).
