# audio-reader

A voice-controlled podcast and RSS/Substack reader, designed for visually impaired users.
iOS app (SwiftUI) backed by a FastAPI service; the phone stays thin and the
backend owns feeds, search, and the LLM that turns spoken requests into actions.

## Layout

- `backend/` — FastAPI + SQLAlchemy 2.0 + Alembic. Feed ingestion, episode
  storage, podcast search, and the voice-command endpoint.
- `ios/` — SwiftUI app (`Hearful`), targeting **iOS 26+**.

The deployment target is iOS 26 because `AnalyzerSpeechRecognizer` uses
`SpeechAnalyzer`, which is the only recogniser that transcribes long-form
speech on-device with no time limit. There is a fallback to the older
`SFSpeechRecognizer` for devices where the analyser's models are missing (the
simulator, notably), so lowering the target is possible — it needs
`@available(iOS 26, *)` on that one class and a check around
`.allowBluetoothHFP` — but it would mean most users landing on the weaker
recogniser.

## iOS development

Requires Xcode with the iOS simulator runtime
(`xcodebuild -downloadPlatform iOS` if `xcrun simctl list runtimes` is empty).

```bash
cd ios && xcodebuild test -scheme Hearful -destination 'platform=iOS Simulator,name=iPhone 17'
```

Day to day, open `ios/Hearful.xcodeproj` and press ⌘R. The app and test targets
use file-system synchronized groups, so files added under `ios/Hearful/` are
picked up automatically without editing the project file.

The app talks to `http://localhost:8000` by default, which the simulator can
reach but a physical device cannot. Override with the `HEARFUL_API_URL`
environment variable in the scheme.

### Deploying to a physical device

Use **Release**, not Debug. Xcode's Debug builds split the app into a stub
executable plus a `.debug.dylib`, and App Intents are read from the main
binary — so Siri shortcuts silently never register from a Debug build.
(`ENABLE_DEBUG_DYLIB = NO` is set for Debug for the same reason.)

```bash
cd ios
xcodebuild build -scheme Hearful -configuration Release \
  -destination 'platform=iOS,id=<device-id>' -allowProvisioningUpdates
xcrun devicectl device install app --device <device-id> \
  ~/Library/Developer/Xcode/DerivedData/Hearful-*/Build/Products/Release-iphoneos/Hearful.app
xcrun devicectl device process launch --device <device-id> \
  --environment-variables '{"HEARFUL_API_URL":"http://<mac-lan-ip>:8000"}' \
  com.henrydashwood.hearful
```

Gotchas that cost real time, in the order they bite:

- **Avoid `devicectl device uninstall`.** It revokes the developer trust *and*
  the Local Network permission, and clears `UserDefaults` (so the saved backend
  address is lost). Installing over the top keeps all three.
- **Reboot the phone if Siri shortcuts do not appear** in the Shortcuts app
  after several installs — the system shortcut index goes stale.
- **Local Network permission** must be granted with the app in the foreground;
  a background App Intent cannot show the prompt. Open the app and make one
  request first.
- **Check the Shortcuts app before debugging phrases.** If the app is not
  listed there, nothing is registered and phrase wording is irrelevant.

`HEARFUL_API_URL` is remembered in `UserDefaults` once set, so a debug launch
pointed at a laptop follows the app around afterwards — including when it is
opened from the home screen with no laptop in sight. When an override is in
force, Settings grows a **Server** section showing the address with a button
to forget it. On an ordinary install that section does not appear.

Before a TestFlight upload, bump `CURRENT_PROJECT_VERSION` — App Store Connect
rejects a build number it has already seen. `MARKETING_VERSION` only needs to
change when the version shown to users does.

To exercise the network and playback path without speaking (the simulator has
no useful microphone), launch with a canned transcript:

```bash
SIMCTL_CHILD_HEARFUL_FAKE_TRANSCRIPT="play the one about the aliens lady" xcrun simctl launch booted com.henrydashwood.hearful
```

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
- `AUDIOREADER_COMMAND_RATE_LIMIT_PER_MINUTE` / `_PER_DAY` — what one account
  may spend on spoken commands (defaults 12 and 500; 0 disables either).
  In-process, so with several replicas the effective limit multiplies.
- `AUDIOREADER_SESSION_IDLE_TIMEOUT_DAYS` — how long a session token stays
  valid after its last use (default 180; 0 disables expiry)
- `AUDIOREADER_FEED_FAILURE_THRESHOLD` — consecutive failed polls before a
  feed is reported as broken and flagged to the app (default 5)
- `AUDIOREADER_ORPHAN_FEED_RETENTION_DAYS` — how long a feed nobody
  subscribes to and nobody has listened to stays in the shared catalog before
  being pruned (default 30)

`GET /health` is the platform healthcheck. It deliberately does not touch the
database: a liveness probe that fails on a brief Postgres blip turns a
recoverable outage into a restart loop.

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
