# audio-reader

**Magpie** — a voice-controlled podcast and RSS/Substack reader, designed for visually impaired users.
iOS app (SwiftUI) backed by a FastAPI service; the phone stays thin and the
backend owns feeds, search, and the LLM that turns spoken requests into actions.

## Layout

- `backend/` — FastAPI + SQLAlchemy 2.0 + Alembic. Feed ingestion, episode
  storage, podcast search, and the voice-command endpoint.
- `ios/` — SwiftUI app, targeting **iOS 26+**. Ships as **Magpie**; the Xcode
  project, target, and bundle identifier keep the original `Hearful` name.

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
make ios-doctor       # verify Xcode and choose a compatible simulator
make ios-build        # compile on the oldest installed iOS 26+ runtime
make ios-index        # refresh Cursor's local SourceKit-LSP build settings
make ios-test         # run the full Swift test suite there
make ios-test-latest  # also check the newest installed runtime
make ios-phone        # Release build, install over Wi-Fi, and launch on the paired iPhone
```

The commands choose an available iPhone automatically and keep DerivedData in
the ignored `build/` directory. Set `IOS_SIMULATOR_ID` to use a specific
simulator. Direct `xcodebuild` commands remain useful for one-off destinations.

Day to day, open `ios/Hearful.xcodeproj` and press ⌘R. The app and test targets
use file-system synchronized groups, so files added under `ios/Hearful/` are
picked up automatically without editing the project file.

The project-level Cursor MCP configuration connects Apple's Xcode tools and
XcodeBuildMCP. Apple's bridge also requires Xcode to be running with the
Hearful project open and **Xcode > Settings > Intelligence > Model Context
Protocol > Xcode Tools** enabled for external agents.

For complete Swift completion and navigation in Cursor, install
`xcode-build-server` once with Homebrew, then refresh its machine-local compile
settings after project or build-setting changes:

```bash
brew install xcode-build-server
make ios-index
```

The generated `buildServer.json`, `.compile`, and raw indexing build log are
ignored. Reload Cursor after the first generation so SourceKit-LSP picks up the
build server.

Debug builds talk to `http://localhost:8000` by default, which the simulator
can reach but a physical device cannot. Start the local database and backend
with development authentication enabled:

```bash
make backend-dev
```

Then run the app from Xcode, Cursor, or Codex. A Debug build pointed at a loopback
server uses the matching local development account automatically, so Sign in
with Apple is not part of the simulator loop. The token is a non-secret marker:
the backend accepts it only when `AUDIOREADER_DEVELOPMENT_AUTH_TOKEN` is set in
the `development` environment, and refuses that setting in production. Release
builds compile out the client-side bypass and default to the deployed backend.

Override the server with the `HEARFUL_API_URL` environment variable when
needed. Set `HEARFUL_DEVELOPMENT_AUTH_TOKEN` as well if the local backend uses
a token other than the repository's development default.

### Deploying to a physical device

Use **Release**, not Debug. Xcode's Debug builds split the app into a stub
executable plus a `.debug.dylib`, and App Intents are read from the main
binary — so Siri shortcuts silently never register from a Debug build.
(`ENABLE_DEBUG_DYLIB = NO` is set for Debug for the same reason.)

```bash
make ios-phone
```

The command finds the one paired physical iPhone, builds a signed Release app,
installs it over the existing copy, and opens it. The phone may connect by USB
or over the same Wi-Fi network. It launches against the deployed Railway API,
clearing any laptop address remembered by an older development run. Set
`IOS_DEVICE_API_URL=http://<mac-lan-ip>:8000` when local phone-to-Mac testing is
intentional. If more than one iPhone is paired, select one with
`IOS_DEVICE_ID=<udid> make ios-phone`. To verify device selection without
building or touching the phone, run `IOS_DEVICE_DRY_RUN=1 make ios-phone`.

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

### Continuous integration

`.github/workflows/ci.yml` is the automatic quality gate for every pull request
and push to `main`. Its Linux job installs the locked backend environment, runs
Ruff formatting and linting, type-checks with ty, executes the backend and
repository-script tests, and validates the App Store listing. Its macOS job
selects Xcode 26 or newer and runs the full iOS simulator test suite.

The Xcode Cloud **Test** workflow is manual-only so it does not duplicate these
checks. GitHub Actions also owns TestFlight releases.

### Releasing to TestFlight

`.github/workflows/testflight.yml` runs the tests, archives, and uploads. It is
not on every push to `main` — a build goes out when a `v*` tag is pushed, or on
demand:

```bash
git tag v1.1.0 && git push origin v1.1.0
```

```bash
gh workflow run testflight.yml --ref main
```

Only a tag reaches external testers. A manual run uploads the build, sets its
release notes, and leaves it with the internal group; pushing a `v*` tag also
adds it to the **Friends and Family** group and submits it for beta app review.
Building and distributing are separate jobs, so a build that uploaded but failed
to distribute can be picked up without rebuilding:

```bash
gh workflow run testflight.yml --ref main -f distribute_build=56
```

Approval is Apple's to give and typically takes a day, so a tag starts that
clock rather than finishing it.

The **What to Test** notes are the topmost `## ` section of
[docs/CHANGELOG.md](docs/CHANGELOG.md) — append a new section before tagging.
On a tag the heading must be the tag without its `v` — `v1.1.0` wants
`## 1.1.0` — so tagging with `## 1.0` still at the top fails the release
instead of shipping last version's notes to testers.

The tag form also sets `MARKETING_VERSION` from the tag (`v1.1.0` → `1.1.0`);
the on-demand form leaves whatever the project carries. Either way the build
number is `git rev-list --count HEAD`, which is unique and always increasing —
so `CURRENT_PROJECT_VERSION` in the project file no longer needs bumping by
hand. It still does for an upload archived locally in Xcode, since App Store
Connect rejects a build number it has already seen.

The workflow needs five repository secrets:

| Secret | What it is |
| --- | --- |
| `APPLE_DISTRIBUTION_CERT_P12` | Apple Distribution certificate + private key, exported from Keychain as `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `APPLE_DISTRIBUTION_CERT_PASSWORD` | The password set when exporting that `.p12` |
| `APP_STORE_CONNECT_KEY_ID` | Key ID of an App Store Connect API key with the App Manager role |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID from the same Keys page |
| `APP_STORE_CONNECT_KEY_P8` | The downloaded `AuthKey_*.p8`, base64-encoded |
| `APPLE_PROVISIONING_PROFILE` | An App Store `.mobileprovision` for `com.henrydashwood.hearful`, base64-encoded |

Uploading from Xcode does not necessarily leave an Apple Distribution
certificate on the Mac — Xcode can sign with a cloud-managed identity whose key
it keeps to itself, and `security find-identity -v -p codesigning` then shows
only the development certificate. CI needs a real one: Xcode → Settings →
Accounts → Manage Certificates → **+** → Apple Distribution, then export it
from Keychain Access as `.p12` (select the certificate *and* its private key).

Signing in CI is **manual**, unlike the project's Automatic setting for local
builds. Automatic signing does not work here: given an API key and
`-allowProvisioningUpdates`, Xcode mints an `Apple Development: Created via API`
certificate, archives with *that*, and then fails at export with `Cloud signing
permission error` — an API key is not allowed to create a distribution profile
through cloud signing. So the workflow installs a profile it is given, and
names it explicitly.

The profile must list the same Apple Distribution certificate as the `.p12`
secret. Xcode's own `iOS Team Store Provisioning Profile` will not do if the app
was ever uploaded from Xcode: that profile is built around a *cloud-managed*
distribution certificate whose private key Apple keeps, so a locally created
certificate is absent from it and signing fails. Create the profile in the
developer portal against the certificate you exported, and regenerate it
whenever that certificate is replaced.

`ios/ExportOptions.plist` uploads straight from `-exportArchive`, so there is no
separate Transporter step. The workflow rewrites the profile entry in a copy of
it with the UUID of the installed profile, so renaming the profile in the portal
cannot break the build.

Distribution happens in a second job, on Linux, because it is only App Store
Connect API calls and most of its time is spent waiting for Apple to finish
processing the build — a macOS runner would sit idle for the same twenty
minutes. [scripts/testflight_distribute.py](scripts/testflight_distribute.py)
does that work and can be run by hand against an already-uploaded build:

```bash
ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_P8_BASE64=... uv run scripts/testflight_distribute.py --build-number 55
```

### App Store listing

The public description, subtitle, keywords, URLs, review notes and screenshot
folders live under [app-store](app-store/README.md). `make ios-build` validates
them offline, and a `v*` release tag synchronises them to the matching editable
iOS version in App Store Connect before it distributes the TestFlight build.
The sync creates the version if needed, but deliberately does not submit it for
review or release it.

Capture the current simulator screen into the correct tracked screenshot set
with:

```bash
IOS_SIMULATOR_ID=<udid> make app-store-screenshot \
  DISPLAY=APP_IPHONE_67 NAME=01-latest
```

Run `make app-store-validate` after any listing change. See the App Store
listing README for the accepted phone and iPad sizes, the local sync command,
and the submission choices that still need a human pass in App Store Connect.

Both the certificate and the provisioning profile expire a year after they were
made — August 2027 for the current pair. Nothing warns you beforehand; the
release simply starts failing. Renewing means creating both again and updating
`APPLE_DISTRIBUTION_CERT_P12` and `APPLE_PROVISIONING_PROFILE`.

To exercise the network and playback path without speaking (the simulator has
no useful microphone), launch with a canned transcript:

```bash
SIMCTL_CHILD_HEARFUL_FAKE_TRANSCRIPT="play the one about the aliens lady" xcrun simctl launch booted com.henrydashwood.hearful
```

## Backend development

Requires [uv](https://docs.astral.sh/uv/) and Docker.

Run the same locked lint, format, type, and test gates used by CI:

```bash
make backend-check
```

For the development server and individual checks:

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
- `AUDIOREADER_DEVELOPMENT_AUTH_TOKEN` — enables the fixed local simulator
  account only when `AUDIOREADER_ENVIRONMENT=development`; production rejects
  any non-empty value
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

`GET /support` serves the public App Store support page from
`src/audioreader/static/support.html`. It keeps the contact path and the most
useful first checks available without an account, and links back to the privacy
policy.

### Telemetry

Traces, logs and metrics go to [Logfire](https://logfire-eu.pydantic.dev)
(the EU instance — a token issued for one region is rejected by the other).
`src/audioreader/telemetry.py` sets it up; FastAPI, httpx and SQLAlchemy are
instrumented, and the existing `logging` calls are forwarded rather than
rewritten, so they still reach stdout and Railway's log view as well.

- `LOGFIRE_TOKEN` — the write token for the `hearful` project, set as a Railway
  service variable and read from `.env` locally. `LOGFIRE_API_KEY` is accepted
  as well, since that is what this project's `.env` has always called it.
  **With no token nothing is sent**, which is what makes tests and local
  development need no configuration at all. Never commit it.
- `AUDIOREADER_ENVIRONMENT` — the label telemetry is filed under. Railway's own
  `RAILWAY_ENVIRONMENT_NAME` is read as a fallback, so a deploy says
  `production` on its own; locally it stays `development`.
- `AUDIOREADER_TELEMETRY_TRANSCRIPTS` — whether her spoken words are attached
  to the telemetry for a command (default true, see below).

The token in `.env` is enough to send from a laptop. To use the CLI as well —
`logfire projects`, and sending from a checkout with no `.env`:

```bash
uv run logfire --base-url='https://logfire-eu.pydantic.dev' auth
uv run logfire --base-url='https://logfire-eu.pydantic.dev' projects use --org 'henry-dashwood' 'hearful'
```

**One wide event per command.** A spoken request emits a single `command` span
carrying everything the pipeline learned, rather than a trail of log lines to
be reassembled later. The reason is that every question worth asking spans the
whole request — *which commands were misunderstood, and what did her library
look like when they were?* — and that is one row to group by, not a search
through many. The line-per-step alternative optimises for writing; this
optimises for asking.

It exists because the HTTP status code answers none of it: a request that plays
the wrong episode is a perfectly successful 200.

| | |
| --- | --- |
| `action` | what she got |
| `model_action` | what the model asked for — the gap between the two is how often we overrode it |
| `failure` | `none`, or how it went nowhere: `invalid_decision`, `episode_not_offered`, `show_not_found`, `invalid_episode_pick`, `episode_not_in_show` |
| `transcript`, `transcript_words` | what she said, and how much of it arrived |
| `conversation_turns`, `expects_reply` | how far into an exchange this was, and whether we asked her something — together, whether clarifying gets anywhere |
| `candidate_count`, `feed_count` | the size and breadth of the haystack |
| `search_query` | the show name the model heard |
| `episode_id`, `episode_title`, `feed_title`, `episode_age_days` | what she was given, and how far back it was reached for |
| `speed` | the multiplier, for `set_speed` |
| `llm_calls`, `llm_input_tokens`, `llm_output_tokens`, `llm_seconds` | what it cost, summed over a request — naming a show asks the model twice |
| `telemetry_id`, `provider`, `model` | which pseudonymous diagnostic stream, and against what |

Deliberately absent: `failure` and `action` are seeded with plain strings
(`none`, `error`) rather than left null, so a group-by buckets successes and
outages alongside every way of failing instead of dropping them.

Some queries this is shaped for:

```sql
-- where commands go wrong, and how often
select action, failure, count(*) from records
where span_name = 'command' group by action, failure order by count(*) desc

-- cost of a spoken command, from real token usage rather than the rate card
select model, avg(attributes->>'llm_input_tokens'), avg(attributes->>'llm_seconds')
from records where span_name = 'command' group by model

-- is the phone truncating her? short transcripts, grouped by outcome
select attributes->>'transcript_words' as words, action, count(*) from records
where span_name = 'command' group by words, action order by words

-- does asking her a question lead anywhere? a clarification she answers
-- arrives as a second row with conversation_turns > 0
select attributes->>'conversation_turns' as turns, action, count(*) from records
where span_name = 'command' group by turns, action order by turns
```

None of that is a correctness label; nothing in a request knows whether it was
right. It is the set of proxies that can be measured without one. Anything it
surfaces belongs in `backend/evals` as a case, which is where a number that
means something comes from.

**No sampling, deliberately.** The usual advice with wide events is to keep
errors and slow requests and sample the healthy remainder at a few percent.
That arithmetic assumes volume this app does not have: twenty commands a day is
not a sampling problem, and throwing away nineteen in twenty successes would
leave the "what does normal look like" baseline too thin to compare a bad week
against. Revisit it if this ever serves more than a handful of people.

**Transcripts are sent, and the privacy policy says so.** Without them a wrong
answer cannot be diagnosed: everything else on the span says what happened and
nothing says what was asked for. The policy's "Keeping the app working" section
discloses this, names Pydantic Logfire, and promises deletion after 30 days.
**That 30 days is Logfire's Personal/Team retention** — moving to a plan with a
longer window makes the policy untrue, so change the policy at the same time.
The same goes for turning `AUDIOREADER_TELEMETRY_TRANSCRIPTS` off.

Two things are kept out deliberately, and both are guarded by
`tests/test_telemetry.py` because both would return silently. The FastAPI
instrumentation is given an explicit attribute mapper: its default uploads
every parsed endpoint argument, which for `POST /command` is the transcript
*and* the `User` row with her email address in it, whatever the setting above
says. And the caller's IP address, which the ASGI instrumentation records on
every request span, is scrubbed — it answers no question this telemetry exists
to answer, and the policy says it never leaves the server.

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
