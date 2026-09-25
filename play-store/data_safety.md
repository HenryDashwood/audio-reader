# Play Data safety form: draft answers

Draft for **Policy and programmes → App content → Data safety** in Play Console.
Nothing here has been submitted. Answers reflect Android release `1.0.0`
(versionCode 1) and the production backend as read from the code on 25 September
2026. Re-check them against the code whenever a release adds a network call, SDK,
or stored field, and keep them consistent with the
[privacy policy](https://audio-reader-production.up.railway.app/privacy).

Items marked **Owner decision** are judgement calls or gaps the code cannot settle.
They are collected at the end.

## What the app ships with

- No advertising, analytics or crash-reporting SDKs. The only third-party runtime
  libraries are AndroidX/Jetpack, Media3, AppFunctions, Credential Manager with
  Google ID, Coil, jsoup and kotlinx-coroutines
  (`android/app/build.gradle.kts`).
- The merged release manifest has no `AD_ID` permission. It requests
  `INTERNET`, `ACCESS_NETWORK_STATE`, `RECORD_AUDIO`, `FOREGROUND_SERVICE`,
  `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, `WAKE_LOCK`, `VIBRATE`, and
  `USE_BIOMETRIC`/`USE_FINGERPRINT`, which Credential Manager merges in
  (`android/app/src/main/AndroidManifest.xml`; the merged copy is
  `android/app/build/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml`).
- All app traffic goes to `https://audio-reader-production.up.railway.app`
  (the release default in `docs/android-release.md`), to Google or Apple for
  sign-in, and directly to podcast/article hosts for audio, artwork and
  article images.

## Section 1: Data collection and security

| Question | Answer | Justification |
| --- | --- | --- |
| Does your app collect or share any of the required user data types? | **Yes** | Account email and identifiers, library activity, voice-request text, newsletters and diagnostics reach the backend. |
| Is all of the user data collected by your app encrypted in transit? | **Yes** | Release builds require an HTTPS API origin (`make android-release-check`, `docs/android-release.md`). The capture WebView rejects mixed content and certificate errors (`android/README.md`, "Incoming sharing and browser capture"). Publisher audio/artwork URLs come from feeds and may be `http:`, but that traffic carries no user data to the developer. **Owner decision:** confirm cleartext is disallowed in release (no `usesCleartextTraffic`/network security config appears in the manifest, so the Android 9+ default of HTTPS-only applies to the app's own requests). |
| Which of the following methods of account creation does your app support? | **OAuth** (Sign in with Google, Sign in with Apple). No username/password. | `android/app/src/main/java/com/henrydashwood/magpie/auth/`; `backend/src/audioreader/auth/service.py` `login()` creates an account on first verified sign-in. |
| Do you provide a way for users to request that their data is deleted? | **Yes** | In app: Settings → Account → Delete Account (`android/README.md`, "Accounts and linked sign-in"). Server: `delete_user()` in `backend/src/audioreader/auth/service.py`. Web: `https://audio-reader-production.up.railway.app/delete-account` (being added separately; confirm it is live before submission). |
| Delete account URL | `https://audio-reader-production.up.railway.app/delete-account` | See `app_content.md`, "Data deletion". |

Play's independent security review badge: **not applicable**; do not claim it.

## Section 2: Data types

"Collected" means sent off the device to the developer (including its service
providers). Play does not count transfers to a **service provider** processing on
the developer's behalf as "sharing": Play Console Help, "Provide information for
Google Play's Data safety section"
(<https://support.google.com/googleplay/android-developer/answer/10787469>),
lists "Transferring user data to a service provider" among the transfers that do
not need to be disclosed as sharing, where the provider processes the data on the
developer's behalf and according to its instructions. Re-read that article before
submitting in case the wording has changed.

**Decided (owner, 25 September 2026):** these are all treated as service
providers, so nothing below is marked **Shared**:

- **OpenAI** (Responses API): interprets voice-request text and typed "Search the
  web" names on Magpie's behalf. API data is not used for training unless the
  customer opts in (Magpie does not), and may be kept in abuse-monitoring logs for
  up to 30 days (`privacy.html`, "When you use voice or AI web search"). The
  backend's default and documented provider is OpenAI
  (`llm_provider` in `backend/src/audioreader/config.py`). The code can also be
  pointed at OpenRouter or Anthropic (`backend/src/audioreader/llm/provider.py`);
  if production ever switches, update the policy and re-check this answer.
- **Railway**: hosting and database.
- **Pydantic Logfire** (EU): request records, operational logs and diagnostics,
  30 days.
- **Cloudflare Email Routing** + the `magpie-email-inbound` Worker
  (`cloudflare/email-worker/`): receives newsletter mail and forwards it to the
  backend unaltered.

Apple's podcast directory (iTunes Search API) receives search terms from the
backend, not from the device and without any user identifier
(`backend/src/audioreader/feeds/search.py`). Treat that as a server-side API call
made to answer the user's request, not sharing.

Nothing is declared as sold, used for advertising, or used for personalisation
beyond carrying out the user's own request.

### Location

Not collected. **Approximate location: No.** The voice request carries a
two-letter `country` code and a timezone name
(`android/app/src/main/java/com/henrydashwood/magpie/voice/VoiceWire.kt`,
`voice/Conversation.kt`). The country is the device locale's region
(`Locale.getDefault().country` in `voice/PlaybackVoiceHost.kt`), not a location
reading. The app has no location permission. These values only select the
podcast directory storefront and resolve relative dates such as "today".

### Personal info

| Data type | Collected | Shared | Processed ephemerally | Required / optional | Purposes |
| --- | --- | --- | --- | --- | --- |
| Name | No | No | n/a | n/a | Google tokens are verified for `sub` and `email` only (`backend/src/audioreader/auth/google.py`). |
| Email address | **Yes** | No | No | **Required** | App functionality; Account management |
| User IDs | **Yes** | No | No | **Required** | App functionality; Account management |
| Address, phone number, race/ethnicity, political or religious beliefs, sexual orientation, other info | No | No | | | |

- Email: taken from the verified Google or Apple identity and stored on the user
  row and identity row (`backend/src/audioreader/auth/service.py`, `login()`).
  Google email is kept only when `email_verified` is true. An Apple user may
  supply a private relay address.
- User IDs: provider subject identifiers, the Magpie account UUID, a hashed
  session token and (Apple only) an encrypted refresh token kept for revocation
  (`privacy.html`, "What we collect, and why").

### Financial info, Health and fitness, Contacts, Calendar, Photos and videos, Files and docs

Not collected. The app has no payments, no health data and no access to contacts,
calendar, media library or files.

### Messages

| Data type | Collected | Shared | Ephemeral | Required / optional | Purposes |
| --- | --- | --- | --- | --- | --- |
| Emails | **Yes** | No | No | **Optional** | App functionality |
| SMS/MMS, other in-app messages | No | | | | |

Newsletters sent to the user's private address (`<three-words>@magpieinbox.com`,
minted on first request by `inbound_address()` in
`backend/src/audioreader/newsletters/service.py`) are received by Cloudflare Email
Routing, signed and POSTed unaltered by the Worker
(`cloudflare/email-worker/src/index.ts`) to `/inbound/email`
(`backend/src/audioreader/routers/inbound.py`), and stored by the backend so they
can be read aloud. Strictly, this mail arrives at the server rather than being
sent from the app, but it is the user's own mail and is presented in the app, so
declaring it is the safer answer. Facts, all from `newsletters/service.py` and
`config.py`:

- Stored per issue: sender name and address, subject, sent date, cleaned
  HTML/text, preview, web-version link, unsubscribe URL (`receive()`,
  `episode_for()`). The raw RFC 822 message (headers, attachments) is kept in
  `inbound_messages` for 7 days (`inbound_raw_retention_days`), then pruned.
- Private: email feeds have `owner_user_id` set and are never in the shared
  catalogue; only a publication's public RSS "companion" feed is shared
  (`newsletters/companions.py`).
- New senders are pending until Follow/Block (`approve()`, `block()`); unanswered
  or unfollowed senders are pruned 30 days after their last message or leaving
  (`newsletter_pending_retention_days`). Block deletes the sender's mail at once,
  calls its List-Unsubscribe URL, and later mail is dropped unstored; the blocked
  feed row (name, sender address) stays until account deletion.
- "Sign up for me" (`POST /newsletters/signups`, `newsletters/signup.py`):
  the server submits only the newsletter address (plus the form's own fields) to
  the publisher's form/Substack/Ghost endpoint and follows confirmation links.
  Sign-up records are pruned after 30 days.
- Account deletion: `delete_all_for_user()` removes feeds, issues, raw messages
  and sign-up records; `delete_user()` removes aliases and the token, after
  which mail to the address is rejected (404 → bounce).
- Pending senders' names and latest subjects, and followed issues' titles,
  are included in voice prompts to OpenAI (`commands/service.py`); email bodies
  are not.

Disclosed in `privacy.html`, "Newsletters". Optional: nothing is created until
the user asks for an address.

### Audio

| Data type | Collected | Notes |
| --- | --- | --- |
| Voice or sound recordings | **No** | Recognition uses `SpeechRecognizer.createOnDeviceSpeechRecognizer` with `EXTRA_PREFER_OFFLINE` and no network fallback (`android/app/src/main/java/com/henrydashwood/magpie/voice/AndroidSpeechInput.kt`; `android/README.md`, "Ask Magpie"). Audio never leaves the device and is not retained, so it is not declared. |
| Music files, other audio files | No | Podcast audio is streamed from publishers; article narration WAV chunks are generated and kept on device only. |

Declare `RECORD_AUDIO` in the permissions section of `app_content.md` instead.

### App activity

| Data type | Collected | Shared | Ephemeral | Required / optional | Purposes |
| --- | --- | --- | --- | --- | --- |
| App interactions | **Yes** | No | No | **Required** | App functionality; Analytics |
| In-app search history | **Yes** | No | **No** | **Optional** | App functionality; Analytics |
| Other user-generated content | **Yes** | No | No | **Optional** | App functionality; Analytics |
| Installed apps | No | | | | |
| Other actions | No | | | | |

- App interactions: followed shows, playback positions, finished/dismissed
  state, article progress bookmarks and the Latest cursor are stored per account
  (`/feeds`, `/episodes/{id}/position`, `/episodes/{id}/article-progress`,
  `/episodes/{id}/state` in
  `android/app/src/main/java/com/henrydashwood/magpie/data/`;
  `backend/src/audioreader/positions.py`, `article_progress.py`). Required because
  the account library is the product. Analytics is added because the optional
  voice-attempt diagnostics (below, "App info and performance") record what
  kind of action was asked for (play, pause, sleep timer). Play takes one
  Required/Optional answer per data type, and the library makes this one
  Required.
- In-app search history: **not ephemeral; retained up to 30 days.** Typed
  searches go in the query string of `GET /search/podcasts?q=`,
  `GET /search/episodes?q=` and `GET /feeds/{id}/episodes?q=`
  (`backend/src/audioreader/routers/feeds.py`; Android
  `data/LibraryApi.kt`, iOS `API/HearfulAPI.swift`). The database does not store
  them, and `_request_attributes` in `backend/src/audioreader/telemetry.py` drops
  parsed endpoint arguments, but Logfire's FastAPI instrumentation still records
  the full URL: a probe on 25 September 2026 showed `http.url` and the span
  message carrying `?q=...`, and the scrubbing patterns (`peer.ip`,
  `client.address` plus Logfire defaults) do not cover it. Directory searches
  are forwarded to `itunes.apple.com/search?term=...`, which `instrument_httpx()`
  and httpx's own INFO log line record too. Logfire keeps both 30 days.
  Purposes: App functionality (answering the search) and Analytics (operational
  logs used to debug). Disclosed in `privacy.html`, "Keeping the app working".
- Other user-generated content, three parts:
  1. **Voice-request text.** The recognised transcript, recent conversation
     turns, and viewed/playing episode IDs are posted to `command/stream`
     (`voice/VoiceWire.kt`, `voice/HttpVoiceApi.kt`). The backend sends the text
     and relevant library titles to OpenAI and keeps a record with the words in
     Logfire for 30 days (`privacy.html`, "Keeping the app working"). Optional:
     voice AI requires explicit in-app consent (`/me/ai-data-sharing`) and the
     app is fully usable on screen without it. Unfinished requests are also kept
     on device in `noBackupFilesDir/voice-requests`
     (`voice/FileConversationStore.kt`). That copy is not collected. Collected,
     not shared: OpenAI processes it as a service provider (Section 2 intro).
     The 30-day Logfire record is why Analytics is listed.
  2. **Saved links and captured article text.** URLs and optional page HTML
     shared to Magpie or captured in its WebView are uploaded to `/saved` and
     `/saved/replace` and kept private to the account
     (`android/app/src/main/java/com/henrydashwood/magpie/sharing/`;
     `backend/src/audioreader/saved.py`). Optional.
  3. **Typed "Search the web" publication names** sent to OpenAI after consent.
     Optional.

**Owner decision:** Play has no exact category for voice-command transcripts.
"Other user-generated content" is the closest. Some developers also tick "Voice
or sound recordings" for speech-derived text. The guidance applies that category
to recordings only, so it is left unticked here.

### Web browsing

| Data type | Collected | Notes |
| --- | --- | --- |
| Web browsing history | **No** | Only pages the user explicitly shares or captures are sent, and those are declared under user-generated content. The capture WebView's cookies stay on device. |

### App info and performance

| Data type | Collected | Shared | Ephemeral | Required / optional | Purposes |
| --- | --- | --- | --- | --- | --- |
| Crash logs | **Yes** | No | No | **Optional** | Analytics |
| Diagnostics | **Yes** | No | No | **Optional** | Analytics |
| Other app performance data | No | | | | |

- Crash logs: Java/native crash and ANR summaries from
  `ApplicationExitInfo` (kind, termination reason, app and OS version, time),
  with no stack traces (`android/app/src/main/java/com/henrydashwood/magpie/telemetry/AndroidExitReporter.kt`).
- Diagnostics: voice-attempt timings and outcomes, recogniser name, whether
  TalkBack was on, and conversation turn count (`telemetry/VoiceAttempt.kt`),
  plus foreground main-thread freezes of 5 s or longer
  (`telemetry/MainThreadDiagnostics.kt`). Posted to `/events/voice` and
  `/events/diagnostic` (`backend/src/audioreader/routers/events.py`) and kept in
  Logfire under a pseudonymous diagnostic ID for 30 days. No transcript, audio,
  or article content.
- **Optional (decided):** Settings → Privacy & Support → Share app diagnostics
  turns both off and clears the queue (`android/README.md`, "Reliability
  diagnostics"). The toggle defaults to **on** (`diagnostics_enabled` defaults
  to `true` in `data/PreviewStore.kt`); the owner has chosen to keep it on by
  default and declare the data Optional because users can turn it off. The
  policy says so ("In Magpie for Android, these diagnostics are on unless you
  switch them off"). iOS has no in-app switch (MetricKit follows the system
  analytics setting; voice-attempt events are always sent), which the policy
  also states; that does not affect the Android form.
- Purpose: Analytics, Play's usual purpose for crash and performance
  monitoring.

### Device or other IDs

**Not collected.** The diagnostic identifier is generated on the server per
account, not taken from the device. The shortcut launch proof and the crash-report
process marker are random values kept on device
(`android/README.md`, "Home screen shortcuts" and "Reliability diagnostics").
No advertising ID or Android ID is read.

## Section 3: Data usage and handling summary (for every declared type)

- **Encrypted in transit:** yes (HTTPS).
- **Users can request deletion:** yes. Delete Account removes the account,
  identities, subscriptions, positions, saved articles, newsletter aliases,
  newsletter feeds, issues, raw emails and sign-up records (`delete_user()` in
  `backend/src/audioreader/auth/service.py`, `delete_all_for_user()` in
  `newsletters/service.py`). Logfire request records remain under the random
  diagnostic code, and operational logs (search URLs; a few newsletter and
  rate-limit lines carrying the account UUID) remain until their 30-day expiry;
  backups last up to 30 days. All disclosed in `privacy.html`.
- **Sold:** no. **Advertising or marketing:** no. **Fraud prevention, security
  and compliance:** not declared. Rate limiting and the OpenAI safety identifier
  are incidental. **Owner decision:** add this purpose if you want to be strict.

## Owner questions

Resolved 25 September 2026: OpenAI and the other processors are service providers
(not shared); newsletters are now in the policy; search terms are retained in
Logfire URLs for 30 days (declared, not ephemeral); diagnostics are Optional with
a default-on Android switch.

Still open:

1. Is the `/delete-account` web page live in production, and does it work
   without the app?
2. Confirm production still uses `llm_provider = openai` (Railway variables were
   not read for this draft).
3. The remaining inline **Owner decision** notes: cleartext confirmation
   (Section 1), the voice-transcript category, and the optional fraud/security
   purpose (Section 3).
