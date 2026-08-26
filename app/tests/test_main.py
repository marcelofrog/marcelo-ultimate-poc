"""Basic smoke tests. The count matters — the Rego promotion gate requires
POC_MIN_PASSING_TESTS successful cases before dev -> qa is allowed."""
from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health_returns_ok():
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert "python" in body


def test_health_reports_configured_stage(monkeypatch):
    monkeypatch.setenv("APP_STAGE", "unit-test")
    r = client.get("/health")
    assert r.status_code == 200


def test_echo_roundtrips_message():
    r = client.post("/echo", json={"message": "hello"})
    assert r.status_code == 200
    assert r.json()["echoed"] == "hello"


def test_echo_rejects_empty_message():
    r = client.post("/echo", json={"message": ""})
    assert r.status_code == 422


def test_openapi_lists_expected_endpoints():
    spec = client.get("/openapi.json").json()
    paths = set(spec["paths"].keys())
    assert {"/health", "/echo", "/outbound-check"}.issubset(paths)
