.PHONY: backend-dev ios-doctor ios-build ios-test ios-test-latest

backend-dev:
	docker compose up -d db
	cd backend && uv run alembic upgrade head
	cd backend && AUDIOREADER_DEVELOPMENT_AUTH_TOKEN=hearful-local-development AUDIOREADER_POLL_INTERVAL_SECONDS=0 uv run uvicorn audioreader.main:app --reload

ios-doctor:
	@./scripts/ios-dev.sh doctor

ios-build:
	@./scripts/ios-dev.sh build

ios-test:
	@./scripts/ios-dev.sh test

ios-test-latest:
	@./scripts/ios-dev.sh test-latest
