# Repository guidance

## General

- Preserve unrelated working-tree changes. This repository is often used for parallel backend and iOS work.
- Do not tag, publish, upload to TestFlight, change credentials, or modify production services unless the user explicitly asks.
- Treat API contract changes as cross-platform: update and verify the FastAPI backend, Swift client, and any affected Android contracts when one side changes.
- Backend releases follow `docs/backend-releases.md`: CI deploys tested `main`
  commits to staging; `.github/workflows/backend-production.yml` owns manual
  production promotion of a verified staging deployment. Do not restore Railway
  push-to-production autodeploys.
- Preserve frozen released-client sources under `compatibility/`. Never update a
  baseline just to make a backend change pass. For API/compatibility changes, run
  `make backend-compatibility` on macOS as well as `make backend-check`.
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

## Android

- The native Kotlin / Compose / Media3 client is under `android/`; read its
  `AGENTS.md` and `README.md` before changing it. Open `android/` in Android Studio.
- Run `make android-doctor` for Java, Gradle, SDK, and emulator diagnostics.
  `make android-check` builds both debug APKs, runs JVM tests, and checks lint.
- Use `make android-emulators` and `ANDROID_AVD=name make android-emulator` to
  start an existing AVD. Run `make android-test` for UI/service changes and
  `make android-run` to install and launch the preview. Set `ANDROID_SERIAL`
  explicitly when more than one emulator is running.
- Use `make android-unit-test TEST='*ClassName'` or
  `make android-test TEST='fully.qualified.ClassName#method'` while iterating;
  omit `TEST` for full verification. `android-check` always runs the full JVM suite.
- Use `make android-layout`, `make android-screenshot`, and `make android-logs`
  to inspect the running emulator. Screenshots/logs stay in ignored
  `build/android-artifacts/`. Inspect screenshots visually when checking UI.
- Google's official Android CLI and `android-cli` skill support environment
  management, UI inspection, and current Android documentation. Use
  `scripts/android-dev.sh cli docs search 'topic'` for API guidance. Check the
  installed CLI's help because its syntax can change independently of Gradle.
- The local device bridge, Gradle services, and CLI cache may need execution
  outside an agent sandbox. Treat socket/cache permission errors as environment
  failures; do not change application code or disable sandboxing to hide them.
- Keep physical-device work intentional: the helper commands target emulators.
  Do not uninstall, clear app data, wipe AVDs, or alter release signing as a
  routine development step. Report emulator coverage separately from phone,
  TalkBack, Bluetooth, and offline voice quality checks.
