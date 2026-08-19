.PHONY: ios-doctor ios-build ios-test ios-test-latest

ios-doctor:
	@./scripts/ios-dev.sh doctor

ios-build:
	@./scripts/ios-dev.sh build

ios-test:
	@./scripts/ios-dev.sh test

ios-test-latest:
	@./scripts/ios-dev.sh test-latest
