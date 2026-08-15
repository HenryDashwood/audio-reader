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

### Evaluating the voice commands

The test suite stubs the model, so it proves the pipeline works and says
nothing about whether the model understands her. That question has its own
corpus of spoken requests paired with the behaviour each should produce:

```bash
uv run python -m evals               # calls a real model; costs money
```

See `backend/evals/README.md`. Everything but the model call is stubbed, so a
run is repeatable and never touches a real feed. Add a case whenever something
goes wrong in real use — before fixing it.

## Configuration

Settings come from environment variables prefixed `AUDIOREADER_` (or a
`backend/.env` file). Defaults match the docker-compose Postgres, so local
development needs no configuration.

- `AUDIOREADER_DATABASE_URL` — Postgres connection string
- `AUDIOREADER_POLL_INTERVAL_SECONDS` — background feed-poll interval
  (default 900; set 0 to disable, e.g. when an external scheduler runs
  `python -m audioreader.feeds.poller` instead)
- `AUDIOREADER_COMMAND_CANDIDATE_LIMIT` — how many recent episodes the model
  chooses between per command (default 60; the main cost dial)
- `AUDIOREADER_COMMAND_SEARCH_LIMIT` — how many older episodes matching what
  she actually said are added to that window (default 15; 0 disables the
  search). Feeds carry their whole archive — In Our Time's is past a thousand
  episodes, back to 1998 — so recency alone puts anything older than a couple
  of months permanently out of reach, however precisely she names it.
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

`GET /privacy` serves the privacy policy from
`src/audioreader/static/privacy.html`. It is the URL registered with App Store
Connect, so it needs to keep working; there is a test asserting it is public and
still names the third parties involved.

### Backups

Two layers, protecting against different things.

**Railway point-in-time recovery** is enabled on the Postgres service. It covers
mistakes — a bad migration, rows deleted by accident — and restores to any
moment. It does not cover losing the project or the account, because it lives
inside them.

**`backend/scripts/backup-db.sh`** covers that second case by putting a dump
somewhere Railway does not control:

```bash
DATABASE_URL='<Railway public connection string>' backend/scripts/backup-db.sh
```

Use the **public** connection string from the Postgres service's Connect tab —
the one in the service variables points at `postgres.railway.internal`, which
only resolves inside Railway. Dumps land in `~/HearfulBackups` (override with
`HEARFUL_BACKUP_DIR`), are `chmod 600`, and anything older than 30 days is
deleted.

That retention is a privacy decision as much as a housekeeping one: the privacy
policy promises deletion is permanent, and a backup kept indefinitely would
quietly make that untrue. If you change `HEARFUL_BACKUP_RETENTION_DAYS`, change
the policy to match.

The dump contains every user's email address, listening history and encrypted
Apple tokens. The script refuses to write anywhere inside this repository, which
is public.

To restore one:

```bash
pg_restore --no-owner --no-privileges -d '<target database url>' hearful-<stamp>.dump
```

### Revoking Sign in with Apple on account deletion

App Store guideline 5.1.1(v) asks that deleting an account also revokes the
Apple grant. That needs a Sign in with Apple key from the developer portal
(Certificates, Identifiers & Profiles → Keys → enable Sign in with Apple,
configured for the app's App ID). The `.p8` downloads exactly once.

- `AUDIOREADER_APPLE_TEAM_ID` — 10 characters, from Membership details
- `AUDIOREADER_APPLE_KEY_ID` — 10 characters, shown on the key's page
- `AUDIOREADER_APPLE_PRIVATE_KEY` — the `.p8` file's contents. Real newlines
  or `\n` escapes both work.
- `AUDIOREADER_APPLE_TOKEN_ENCRYPTION_KEY` — a Fernet key encrypting the
  stored refresh tokens. Generate one with:

  ```bash
  python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
  ```

Leave any of the first three blank and revocation is skipped entirely —
deletion still works, it just goes unreported. That is deliberate: erasing her
data must never depend on Apple being reachable, and the same is true if the
encryption key is lost or rotated. The worst case is always an un-revoked
grant, never an account that outlives the request to delete it.

The chain is: the app sends Apple's single-use `authorization_code` at
sign-in → the backend trades it for a refresh token and stores it encrypted on
`user_identities` → `DELETE /me` revokes with that token before deleting the
row. Accounts created before this existed have no token and simply skip the
revocation step until their next sign-in.

The test suite stubs the LLM, so no API key is needed to run it.

### Choosing an LLM provider

`AUDIOREADER_LLM_PROVIDER` selects the backend; the bare vendor key names
(`ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`) are read as-is from `.env`.

| Provider | Key | Model setting |
| --- | --- | --- |
| `openrouter` (default) | `OPENROUTER_API_KEY` | `AUDIOREADER_OPENROUTER_MODEL` |
| `anthropic` | `ANTHROPIC_API_KEY` | `AUDIOREADER_LLM_MODEL` |

The default is `openai/gpt-5.6-luna`. Model choice is decided by
`backend/evals` rather than by impressions — the numbers below are that
corpus run three times over, alongside the cost of one spoken command measured
from real token usage:

| Model | $ / command | Corpus, 66 runs |
| --- | --- | --- |
| `openai/gpt-5.6-luna` | 0.00039 | 66 pass |
| `deepseek/deepseek-v4-flash` | 0.00023 | 62 pass, 4 fail |
| `deepseek/deepseek-v4-flash-0731` | 0.00049 | 59 pass, 3 fail, 3 error |
| `anthropic/claude-opus-5` | 0.03352 | clean, at 85× the price |

DeepSeek V4 Flash held the default until it was measured properly: it returns
malformed JSON on a few percent of calls, and it misroutes requests for shows
she does not subscribe to. Luna is the only cheap model to score the corpus
clean, and it is quicker.

Two things that are easy to get wrong here. **Input price is very nearly the
only price that matters**: one command is about 3,500 input tokens against 45
output, so Luna wins on cost despite its output tokens costing twice
DeepSeek's. And **cost is not really what decides this** — at twenty commands a
day every cheap option lands between 15p and 30p a month, and even Opus is
about £16. Treat the choice as one of reliability with a rounding error
attached.

The `openrouter` client speaks the OpenAI chat-completions format, so pointing
`AUDIOREADER_OPENROUTER_BASE_URL` elsewhere reaches OpenAI, DeepSeek direct,
Groq, or a local vLLM without new code.
