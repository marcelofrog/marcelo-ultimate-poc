"""
Ultimate POC — sample FastAPI service.

Deliberately pulls in a handful of packages that are frequently targeted by
supply-chain attacks (requests, httpx, pydantic, uvicorn, python-multipart).
The point is to give Curation something interesting to inspect.

The endpoints are small on purpose — this file exists to be built, scanned,
promoted, and deployed, not to teach FastAPI.
"""
from __future__ import annotations

import os
import platform
from datetime import datetime, timezone

import httpx
import requests
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

APP_NAME = os.getenv("APP_NAME", "ultimate-poc")
APP_STAGE = os.getenv("APP_STAGE", "dev")
APP_VERSION = os.getenv("APP_VERSION", "0.0.0-local")

app = FastAPI(
    title=f"{APP_NAME} ({APP_STAGE})",
    version=APP_VERSION,
    description="Ultimate POC sample service — demonstrates JFrog end-to-end promotion.",
)


class Health(BaseModel):
    status: str = Field("ok")
    app: str
    stage: str
    version: str
    time: datetime
    python: str


class EchoIn(BaseModel):
    message: str = Field(..., min_length=1, max_length=500)


class EchoOut(BaseModel):
    echoed: str
    served_by: str



@app.get("/health", response_model=Health)
def health() -> Health:
    return Health(
        app=APP_NAME,
        stage=APP_STAGE,
        version=APP_VERSION,
        time=datetime.now(timezone.utc),
        python=platform.python_version(),
    )


@app.post("/echo", response_model=EchoOut)
def echo(payload: EchoIn) -> EchoOut:
    return EchoOut(echoed=payload.message, served_by=f"{APP_NAME}@{APP_STAGE}")


@app.get("/outbound-check")
def outbound_check() -> dict[str, str]:
    """Tiny endpoint that exercises both requests and httpx, so the images
    that would be blocked by Curation on a malicious/immature version would
    fail loudly instead of silently."""
    try:
        r = requests.get("https://example.com", timeout=3)
        r.raise_for_status()
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=f"requests failed: {e}") from e

    try:
        async_ok = httpx.get("https://example.com", timeout=3).status_code == 200
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=f"httpx failed: {e}") from e

    return {"requests": "ok", "httpx": "ok" if async_ok else "fail"}
