# -----------------------------------------------------------------------------
# Ultimate POC — application Dockerfile
#
# Both the base image AND the Python modules must come from JFrog curated
# repositories. Two build-time ARGs make this explicit:
#
#   JF_DOCKER_REGISTRY   e.g. mytenant.jfrog.io
#   JF_DOCKER_REMOTE     e.g. ultimate-demo-docker-remote
#   JF_PYPI_INDEX_URL    full https URL of the curated PyPI index, including
#                        credentials or an empty scope for OIDC-injected tokens
#
# The build workflow supplies all three via `docker build --build-arg`. Local
# builds should `.env` them and use --build-arg $(name)=$(value) as well.
# -----------------------------------------------------------------------------

ARG JF_DOCKER_REGISTRY
ARG JF_DOCKER_REMOTE

# Base image pulled *through* the curated Docker remote — never from Docker Hub
# directly. Curation policies are enforced on the pull.
FROM ${JF_DOCKER_REGISTRY}/${JF_DOCKER_REMOTE}/library/python:3.12-slim AS runtime

ARG JF_PYPI_INDEX_URL

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN useradd --create-home --shell /bin/bash app
WORKDIR /home/app

COPY --chown=app:app requirements.txt ./

# Install from the curated PyPI remote. --index-url overrides pypi.org so the
# request cannot escape Curation.
RUN pip install --no-cache-dir \
      --index-url "${JF_PYPI_INDEX_URL}" \
      -r requirements.txt

COPY --chown=app:app main.py ./

USER app
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=2).status==200 else 1)"

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
