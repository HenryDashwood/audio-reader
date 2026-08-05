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
uv run ruff check && uv run ruff format --check
uv run ty check               # type checking
uv run uvicorn audioreader.main:app --reload
uv run python -m audioreader.feeds.poller   # one-shot poll of all feeds
```

Tests run against in-memory SQLite and mocked HTTP, so they need neither the
database container nor a network connection.

## Configuration

Settings come from environment variables prefixed `AUDIOREADER_` (or a
`backend/.env` file). Defaults match the docker-compose Postgres, so local
development needs no configuration.

- `AUDIOREADER_DATABASE_URL` — Postgres connection string
- `AUDIOREADER_POLL_INTERVAL_SECONDS` — background feed-poll interval
  (default 900; set 0 to disable, e.g. when an external scheduler runs
  `python -m audioreader.feeds.poller` instead)
- `AUDIOREADER_COMMAND_CANDIDATE_LIMIT` — how many episodes the model chooses
  between per command (default 60; the main cost dial)

The test suite stubs the LLM, so no API key is needed to run it.

### Choosing an LLM provider

`AUDIOREADER_LLM_PROVIDER` selects the backend; the bare vendor key names
(`ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`) are read as-is from `.env`.

| Provider | Key | Model setting |
| --- | --- | --- |
| `openrouter` (default) | `OPENROUTER_API_KEY` | `AUDIOREADER_OPENROUTER_MODEL` |
| `anthropic` | `ANTHROPIC_API_KEY` | `AUDIOREADER_LLM_MODEL` |

The default is `deepseek/deepseek-v4-flash-0731`, which matched Claude Opus 5
on every episode-selection query we tried at roughly 1/55 of the cost.

The `openrouter` client speaks the OpenAI chat-completions format, so pointing
`AUDIOREADER_OPENROUTER_BASE_URL` elsewhere reaches OpenAI, DeepSeek direct,
Groq, or a local vLLM without new code.
