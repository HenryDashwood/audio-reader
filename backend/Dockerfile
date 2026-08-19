FROM python:3.13-slim-bookworm

# uv from PyPI rather than a separate registry: one less place the build can
# fail for reasons unrelated to this project.
RUN pip install --no-cache-dir uv==0.11.17

WORKDIR /app

# Dependencies first, so code edits do not invalidate the dependency layer.
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY . .
RUN uv sync --frozen --no-dev

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1

# Migrations run on every boot: the schema must match the code that is about
# to serve requests, and Alembic is a no-op when there is nothing to apply.
# $PORT is supplied by the platform.
CMD alembic upgrade head && \
    uvicorn audioreader.main:app --host 0.0.0.0 --port ${PORT:-8000} --no-access-log
