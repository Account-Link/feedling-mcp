# Feedling — backend + MCP server container image.
#
# One image, two entrypoints (CMD-selected) for the Flask HTTP API and the
# FastMCP SSE server. Non-root, minimal, stateless — state lives in the
# mounted /data volume.
#
# Phase 0 (today): ordinary multi-tenant Python app.
# Phase 1 (later, see docs/DESIGN_E2E.md): the mcp service moves into a
# dstack TDX CVM. This Dockerfile is the deployment unit for both.
# Reproducibility is intentionally loose in phase 0; when we ship to TDX
# we'll pin the base image by digest and enable --require-hashes on pip.

ARG PYTHON_IMAGE=python:3.12-slim
FROM ${PYTHON_IMAGE} AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    FEEDLING_DATA_DIR=/data

WORKDIR /app

# System deps for wheels that compile from source (cryptography, pynacl, …).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        libssl-dev \
        libffi-dev \
        curl \
 && rm -rf /var/lib/apt/lists/*

COPY backend/requirements.txt ./requirements.txt
RUN pip install --upgrade pip \
 && pip install -r requirements.txt

COPY backend/ ./backend/

# Run as a fixed non-root UID so bind-mounted volumes on the host can be
# chowned predictably.
RUN useradd --system --uid 1000 --home-dir /home/feedling --create-home feedling \
 && mkdir -p /data \
 && chown -R feedling:feedling /data /app
USER feedling

EXPOSE 5001 5002 9998

# Default command runs the Flask backend. docker-compose overrides for the
# MCP service.
CMD ["python", "-u", "backend/app.py"]
