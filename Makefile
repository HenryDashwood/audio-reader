.PHONY: backend-dev backend-check ios-doctor ios-build ios-index ios-test ios-test-latest ios-phone app-store-validate app-store-fixtures app-store-backend app-store-screenshot app-store-sync

backend-dev:
	docker compose up -d db
	cd backend && uv run alembic upgrade head
	cd backend && AUDIOREADER_DEVELOPMENT_AUTH_TOKEN=hearful-local-development AUDIOREADER_POLL_INTERVAL_SECONDS=0 uv run uvicorn audioreader.main:app --reload

backend-check:
	cd backend && uv sync --frozen
	cd backend && uv run ruff check
	cd backend && uv run ruff format --check
	cd backend && uv run ty check
	cd backend && uv run pytest
	cd backend && uv run pytest ../scripts/tests

ios-doctor:
	@./scripts/ios-dev.sh doctor

ios-build: app-store-validate
	@./scripts/ios-dev.sh build

ios-index:
	@./scripts/ios-dev.sh index

ios-test:
	@./scripts/ios-dev.sh test

ios-test-latest:
	@./scripts/ios-dev.sh test-latest

ios-phone:
	@./scripts/ios-dev.sh device

app-store-validate:
	@python3 scripts/app_store_sync.py validate

app-store-fixtures:
	@mkdir -p build
	@cd backend && AUDIOREADER_ENVIRONMENT=development AUDIOREADER_DATABASE_URL="sqlite+aiosqlite:///$(CURDIR)/build/app-store-screenshots.sqlite" uv run python ../scripts/seed_app_store_screenshots.py

app-store-backend:
	@cd backend && AUDIOREADER_ENVIRONMENT=development AUDIOREADER_DEVELOPMENT_AUTH_TOKEN=hearful-local-development AUDIOREADER_POLL_INTERVAL_SECONDS=0 AUDIOREADER_DATABASE_URL="sqlite+aiosqlite:///$(CURDIR)/build/app-store-screenshots.sqlite" uv run uvicorn audioreader.main:app --reload

app-store-screenshot:
	@./scripts/capture_app_store_screenshot.sh

app-store-sync:
	@test -n "$(VERSION)" || (echo "VERSION is required, for example: make app-store-sync VERSION=1.0" >&2; exit 2)
	@uv run scripts/app_store_sync.py sync --version "$(VERSION)"
