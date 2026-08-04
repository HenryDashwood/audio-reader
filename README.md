# audio-reader

A voice-controlled podcast and RSS/Substack reader, designed for visually impaired users.
iOS app (SwiftUI) backed by a FastAPI service; the phone stays thin and the
backend owns feeds, search, and the LLM that turns spoken requests into actions.

## Layout

- `backend/` — FastAPI + SQLAlchemy 2.0 + Alembic. Feed ingestion, episode
  storage, and (soon) the voice-command endpoint.
- `ios/` — SwiftUI app (not started yet).

## Backend development

Requires [uv](https://docs.astral.sh/uv/) and Docker.

```bash
docker compose up -d          # Postgres 17 on localhost:5432
cd backend
uv sync                       # install dependencies
uv run alembic upgrade head   # apply migrations
uv run pytest                 # run the test suite (no DB or network needed)
uv run uvicorn audioreader.main:app --reload
```

Tests run against in-memory SQLite and mocked HTTP, so they need neither the
database container nor a network connection.

## Configuration

Settings come from environment variables prefixed `AUDIOREADER_` (or a
`backend/.env` file). Defaults match the docker-compose Postgres, so local
development needs no configuration.
