.PHONY: backend-dev ios-packages ios-doctor ios-build ios-test ios-test-latest ios-phone \
	ios-assets-license ios-assets-setup ios-assets-package ios-assets-serve \
	ios-assets-doctor

backend-dev:
	docker compose up -d db
	cd backend && uv run alembic upgrade head
	cd backend && AUDIOREADER_DEVELOPMENT_AUTH_TOKEN=hearful-local-development AUDIOREADER_POLL_INTERVAL_SECONDS=0 uv run uvicorn audioreader.main:app --reload

ios-packages:
	@./scripts/bootstrap-kokoro-packages.sh

ios-doctor: ios-packages
	@./scripts/ios-dev.sh doctor

ios-build: ios-packages
	@./scripts/ios-dev.sh build

ios-test: ios-packages
	@./scripts/ios-dev.sh test

ios-test-latest: ios-packages
	@./scripts/ios-dev.sh test-latest

ios-phone: ios-packages
	@./scripts/ios-dev.sh device

ios-assets-license:
	@./scripts/ios-assets-local.sh license

ios-assets-setup:
	@./scripts/ios-assets-local.sh setup

ios-assets-package:
	@./scripts/ios-assets-local.sh package

ios-assets-serve:
	@./scripts/ios-assets-local.sh serve

ios-assets-doctor:
	@./scripts/ios-assets-local.sh doctor
