# Repository guidance

## General

- Preserve unrelated working-tree changes. This repository is often used for parallel backend and iOS work.
- Do not tag, publish, upload to TestFlight, change credentials, or modify production services unless the user explicitly asks.
- Treat API contract changes as cross-platform: update and verify both the FastAPI backend and the Swift client when either side changes.
- GitHub Actions owns automatic pull-request and `main` CI. The Xcode Cloud Test workflow is manual-only, and `.github/workflows/testflight.yml` owns releases.

## Backend

- Run `make backend-check` for the complete local CI gate: frozen dependency sync, Ruff lint and formatting, ty, backend tests, and repository-script tests.
- Backend and repository-script tests use mocks and in-memory SQLite, so they require neither Docker nor network access.

## iOS

- The app is `ios/Hearful.xcodeproj`, scheme `Hearful`, written in Swift 6 and SwiftUI with an iOS 26 deployment target.
- The product's user-facing name is **Magpie** (display name, Siri phrases, store metadata, spoken strings). The Xcode project, scheme, target, module, folder names, bundle identifier, and `UserDefaults`/Keychain keys deliberately remain `Hearful`; do not rename them.
- Run `make ios-doctor` when diagnosing the local Apple toolchain. Use `make ios-build` for a compile check and `make ios-test` for the full Swift Testing suite. `make ios-test-latest` adds coverage on the newest installed iOS runtime.
- The commands select the oldest installed compatible runtime by default. Set `IOS_SIMULATOR_ID` to target a particular simulator.
- Files below `ios/Hearful/` and `ios/HearfulTests/` belong to Xcode file-system synchronized groups. Do not hand-edit `project.pbxproj` merely to add or remove source files.
- Keep Swift concurrency checks clean. Do not silence Sendable or actor-isolation diagnostics without explaining why the underlying access is safe.
- Accessibility is a product requirement: preserve VoiceOver semantics, Dynamic Type, sufficient contrast, and non-visual feedback when changing UI or playback flows.
- The simulator microphone is not representative. Use the documented `SIMCTL_CHILD_HEARFUL_FAKE_TRANSCRIPT` launch path for voice-flow checks.
- Do not change the deployment target, bundle identifiers, development team, entitlements, signing style, or version numbers unless the task requires it.
- Never uninstall the app from a physical device as a routine debugging step; the repository README explains why. Build physical-device installs in Release, not Debug.

## Verification

- For backend changes, run `make backend-check`.
- For isolated Swift logic changes, run the relevant test or the full `make ios-test` suite.
- For project settings, app entry points, or broad refactors, run both `make ios-build` and `make ios-test`.
- For SDK-sensitive changes, also run `make ios-test-latest` when a newer simulator runtime is installed.
- Report compiler warnings separately from test failures; do not present a warning-bearing build as clean.

