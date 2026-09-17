# Magpie for Android

A native Kotlin / Jetpack Compose client. Signed-in builds load the account
library; signed-out builds provide a separate sample library without a backend
or network connection. Open this `android/` directory in Android Studio.
The app is labelled **Magpie Preview** and debug installs use
`com.henrydashwood.magpie.dev`.

## Run locally

Use Android Studio **Quail 4 / 2026.1.4** or newer, Android SDK platform **37.0**,
and build tools **36.0.0**. The project uses Android Gradle plugin **9.4.0** and
the checksum-verified Gradle **9.7.1** wrapper. Quail 4 supports this plugin version;
see Google's [Studio compatibility table](https://developer.android.com/studio/releases#android_gradle_plugin_and_android_studio_compatibility).
Create a phone in Device Manager using an ARM64 Google Play image on Apple Silicon
(x86_64 on an Intel host). Android 12 / API 31 is the minimum supported version;
the initial local emulator uses Android 16 / API 36. Google Play images do not
necessarily contain downloaded offline voices.

From the repository root:

```sh
make android-doctor  # launcher/daemon Java, Gradle, required SDK, virtual devices
make android-emulators # list AVDs
make android-emulator  # boot the only AVD, or set ANDROID_AVD=name
make android-build   # compile the debug APK
make android-check   # compile app and test APKs, all JVM tests, Android lint
make android-unit-test # JVM tests only; TEST='*ArticleChunksTest' selects a class
make android-test    # Compose UI and Media3 integration tests on one running emulator
make android-run     # build, install over the existing emulator app, launch
make android-layout  # inspect controls and accessibility labels as JSON
make android-screenshot # save emulator PNG under build/android-artifacts/
make android-logs     # save logs from the running Magpie process there
```

Select a particular emulator with `ANDROID_SERIAL=emulator-5554`. These scripts
refuse physical-device installs. Use Android Studio for an intentional phone
install when the Pixel arrives. They never uninstall the app or erase its data.

The wrapper launches using Android Studio's bundled Java on macOS, unless
`JAVA_HOME` is set. Gradle itself runs on **Java 21**, matching CI. The committed
daemon criteria and Foojay resolver download it automatically when needed.
Java 21 keeps Android's bundled test-runner libraries on a compatible LTS runtime;
Java 25 reports deprecated Unsafe access from the runner's Protobuf dependency.
Set `ANDROID_HOME` for a nonstandard SDK location. Gradle caches from these
commands live under ignored `build/android-gradle/`; Android Studio may use its
own standard cache. The committed wrapper checks its Gradle distribution checksum.

### Android CLI and SDK setup

Install Google's [official Android CLI](https://developer.android.com/tools/agents/android-cli)
using the installer linked from Google's
[Android CLI skill](https://github.com/android/skills/tree/main/devtools/android-cli).
On Apple Silicon, download and inspect the installer, then run it:

```sh
curl -fsSL https://dl.google.com/android/cli/latest/darwin_arm64/install.sh -o /tmp/install-android-cli.sh
less /tmp/install-android-cli.sh
bash /tmp/install-android-cli.sh
```

Google installs the launcher at `~/.local/bin/android`. The repository helper
finds it there even if a GUI-launched terminal has not refreshed its PATH.
Set `ANDROID_CLI` for a different executable. The CLI is needed for emulator
startup and layout inspection, but is not a dependency of the Gradle build/CI.
The September 2026 setup was verified with CLI `1.0.16261425`; use its `--help`
for current syntax. Google now recommends the CLI's SDK commands in place of
[`sdkmanager`](https://developer.android.com/tools/sdkmanager).

The helper supplies the same SDK location to Gradle, adb, and the CLI:

```sh
./scripts/android-dev.sh cli sdk list
./scripts/android-dev.sh cli sdk install platforms/android-37.0 build-tools/36.0.0 platform-tools emulator
./scripts/android-dev.sh cli emulator create --list-profiles
./scripts/android-dev.sh cli emulator create medium_phone
./scripts/android-dev.sh cli docs search 'Compose accessibility semantics'
```

Creating an AVD is a one-time step if none exists. Use Android Studio Device
Manager to choose an exact API/image: API 31 for minimum-version coverage, API 36
for the established preview emulator, and API 37 for current target behaviour.
Match the image ABI to the host. The CLI's template chooses its own API; inspect
the resulting AVD before claiming version coverage. Do not overwrite an existing
AVD to change its API. The CLI downloads tools/images as needed, so first setup
requires network access and additional disk space.

`ANDROID_HOME` takes precedence over legacy `ANDROID_SDK_ROOT`; without either,
the helper uses `~/Library/Android/sdk` on macOS or `~/Android/Sdk` on Linux.
Keep Android Studio's ignored `local.properties` SDK path aligned with that
location. No NDK, CMake, or separate system-wide Kotlin/Gradle install is needed
for the current Kotlin application.

Codex can use Google's [`android-cli` skill](https://github.com/android/skills/tree/main/devtools/android-cli)
for current command and UI-inspection guidance. It is installed locally on this
development Mac; other machines can install that directory using the Codex Skill
Installer. Repository-specific rules live in `AGENTS.md`, so builds and tests
remain usable without an agent plugin. Android Studio provides Kotlin indexing,
debugging, profiling, and Compose previews; open this directory for those tools.
The CLI also connects directly to a running Studio project for symbol navigation,
file analysis, and Compose previews. On this Mac, `studio check` reported Magpie
ready and Kotlin file analysis succeeded:

```sh
./scripts/android-dev.sh cli studio check
./scripts/android-dev.sh cli studio analyze-file --project=Magpie android/app/src/main/java/com/henrydashwood/magpie/playback/ArticleChunks.kt
```

### Tests, reports, and debugging

```sh
make android-unit-test TEST='*ArticleChunksTest'
make android-test TEST='com.henrydashwood.magpie.MagpieNavigationTest'
ANDROID_AVD=medium_phone make android-emulator
ANDROID_SERIAL=emulator-5554 make android-run
```

For instrumented tests, `TEST` accepts a fully qualified class or `Class#method`;
for JVM tests it accepts Gradle's `--tests` pattern. Omit it for the full suite.
`android-check` ignores `TEST` and always includes all JVM tests. Instrumented
tests change preview state/preferences; run them on development emulators.
The build gate compiles the instrumentation APK even when no emulator is present.
Espresso is explicitly pinned to 3.7.0: older versions pulled in by Compose
reflect on `InputManager.getInstance`, which is absent on the API 36.1 emulator.
The [AndroidX Test release notes](https://developer.android.com/jetpack/androidx/releases/test#espresso-3.7.0)
document the fix to use the system service instead.

Reports are under `android/app/build/reports/`: `tests/testDebugUnitTest/`,
`androidTests/connected/debug/`, and `lint-results-debug.html`. Raw test XML is
under `android/app/build/test-results/` and `outputs/androidTest-results/`.
CI retains these reports even when a check fails. The debug APK is
`android/app/build/outputs/apk/debug/app-debug.apk`.

Screenshot and log filenames include the selected serial and timestamp.
`android-logs` captures the current app process without clearing the log buffer;
if the process crashed, inspect the crash buffer directly:

```sh
"${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb" -s emulator-5554 logcat -b crash -d
```

Use layout inspection to find controls and their bounds, then `adb -s SERIAL
shell input ...` for deliberate taps or swipes. View captured PNGs to verify
appearance; successful capture alone is not a UI check. Neither layout dumps nor
screenshots establish TalkBack speech or audio quality.

Agent sandboxes can block adb's localhost socket, Gradle services, and writes to
the CLI cache under `~/.android/`. Retry the specific development command through
the agent's normal execution approval mechanism when that occurs. No global
permission relaxation is needed. `android-doctor` distinguishes launcher Java
(currently Studio's Java 25) from Gradle's pinned Java 21 runtime.

## What works

- Following, Latest, Saved, source detail, local library search, and a rich article reader.
- Article/episode toolbars with playback, original-page opening, Android sharing,
  find, and an Ask Magpie entry point. Original-page opening requires a web URL;
  samples share their text. Ask opens a conversation with microphone and typed input.
- The same Ask Magpie control is available on Following, Latest, Saved, Settings,
  and feed pages, including during search. Browser links use Material's Open in new icon.
- Light/dark themes, scalable text, labelled controls, heading semantics, and
  scrollable layouts. Automated checks exercise 200% text; physical TalkBack
  acceptance is still required.
- Following, Latest, and Saved load from the signed-in account. Feed pages and
  library search use the backend, including feeds with no episodes. Saved article
  versions load on demand into the existing rich reader. Refresh reloads the
  account; failed requests retain the current account data with a retry control.
- Save/remove articles and file them under To read or Finished. Signed-in changes
  update the backend; signed-out sample changes remain local.
- Reaching the end of a podcast or narrated article records it as finished (on
  the backend when signed in),
  plays a quiet completion tone, and clears the player and sleep timer. Saved
  articles move to Finished without reopening the screen. The completed player
  stays closed after recreation/relaunch; explicitly playing the item starts over.
- Clear Latest uses a confirmation dialog and updates the account cursor while
  signed in, or persists the current sample item IDs as dismissed locally, without marking them played/read or changing Saved, feed pages,
  or playback bookmarks. New IDs remain eligible for Latest.
- Saved's + button keeps links in a durable account-scoped queue before uploading.
  Pending links retry when Saved opens, on refresh, or with Sync saved links;
  confirmed captures leave the queue. Failed article captures offer Retry and
  Open original. Replace saved text asks for confirmation and preserves the old
  copy on failure; changed content stops old narration and resets its bookmark.
  Signed-out captures use a separate device inbox that never uploads automatically;
  Review device links offers an explicit, confirmed import into the current account.
- Magpie appears in the Android share sheet for one web link, including browser
  text containing a link and optional shared HTML. A scrollable preview requires
  confirmation and sign-in before writing to that account's durable queue.
  Capture page opens an HTTPS page inside Magpie, lets the user sign in to the
  website if needed, and previews the visible article before saving. The same
  pinned Readability script used by iOS is bundled at build time. Original-browser
  cookies are not imported; JavaScript has no native bridge or app credentials.
  Saved articles also offer Capture page to recover pages the server cannot read.
  Open Magpie prepares confirmed captures; Done returns to the sharing app.
- Separate persisted podcast/article speeds, an installed offline voice chooser,
  voice previews, and links to voice downloads, privacy, and email support.
- A native Material mini player with artwork/title, contextual Follow, play/pause,
  a Stop and close (×) button, and a decorative progress line. Controls have 48dp
  touch targets; narrow screens and large text give the title a separate row.
  Closing saves the bookmark, cancels pending narration and the sleep timer,
  stops/clears session media, and forgets the last item so the bar stays dismissed
  after recreation/relaunch. Explicit Play brings it back from the saved position.
- A bundled original sample recording, a mini player and full player, seek,
  pause/resume, and playback speed from 0.5× to 3×.
- A sleep timer beside playback speed, with the iOS choices of 5, 10, 15, 30,
  45, and 60 minutes, a rounded-up countdown, replacement, and cancellation.
  The playback service owns its monotonic deadline, so closing the player or
  backgrounding/recreating the activity does not reset it. Playback speed and
  pauses do not extend the timer. Expiry pauses audio, preserves the bookmark,
  cancels pending narration, and plays a quiet completion tone only if audio was
  playing. Timers clear when the service/process ends and are not restored after
  a restart. Ask Magpie can also set and cancel the timer.
- Media3 playback owned by a `MediaSessionService`, with system media controls,
  audio focus, unplug-to-pause, and playback independent of the activity.
- Google offline TTS rendered into short WAV chunks and assembled into **one**
  playable article. Preparation can be cancelled; missing offline voices produce
  an explicit explanation. No network TTS fallback is selected.

The sample WAV is an original Magpie introduction, generated with the Mac's
installed Alex voice. Its matching transcript is in `data/Library.kt`. It is
bundled so playback tests don't depend on a publisher's stream or a network.

## Article content

The article reader displays HTML in a WebView, with headings, emphasis, lists,
links, images and captions, quotations, code blocks, tables, native MathML, and
inline YouTube/Vimeo video players. Players require a tap and an internet
connection, fit the article width, and have an **Open video in browser** fallback
for unavailable/restricted embeds or full-screen viewing. Arbitrary iframes and
publisher-specific video widgets remain unsupported.
Wide code, tables, and display equations scroll inside the article. The reader
follows the app's light/dark colors and system font scale, supports text selection,
and searches the rendered page with previous/next match controls. HTML semantics,
image alternative text, and table headers remain available to TalkBack.

`LibraryItem.html` is optional display content; `text` remains the immutable
spoken text used for narration and UTF-16 bookmarks. Plain-text items fall back
to escaped paragraphs. Like iOS, the Android reader expects the backend's existing
LaTeX-to-MathML output; it does not interpret raw LaTeX or Markdown itself. MathML
requires an up-to-date Android System WebView. No backend API or iOS contract was
changed. Signed-in article fetching uses the same endpoint and pinned saved
content ID as iOS.

A native gutter marker follows the spoken line and stays at its position while
paused. Seeking, speed changes and reopening the activity use the service's media
timeline. Scrolling by touch or accessibility, or searching the page, stops
following until **Follow reading position** in the mini player is used. The
Follow icon appears only for the currently playing article while its reader is
visible and detached; navigating elsewhere removes that action.
Automatic scrolling is suppressed during touch exploration. The marker is
purely visual and does not interrupt TalkBack announcements or text selection.

The renderer records the voice's `onRangeStart` sample frames while synthesizing
and maps them into the joined WAV's timeline. Engines without word-range callbacks
use the current sentence's start (bounded chunks for unusually long sentences);
no word timings are estimated. The display aligns
spoken UTF-16 ranges with common word runs in the HTML, skipping URLs and MathML,
matching the iOS approach. Unmatched content may have no exact visual position.

HTML is sanitized with jsoup. Article scripts are stripped and blocked by CSP;
only bundled app-owned geometry code is explicitly evaluated. No JavaScript-to-
native interface is exposed. Forms and local file/content access are disabled.
Only canonical YouTube/Vimeo embed URLs survive sanitization and CSP; player
scripts execute in sandboxed remote frames. Players receive the app origin as
the referrer; ordinary article images still suppress referrers. Web links open externally; remote images use
HTTPS without referrers or third-party cookies. Image bytes aren't explicitly
cached for offline use yet. The bundled **Field notes → Reading beyond plain text**
sample includes an offline image, quotes, code, inline/display equations, and a
table. `ArticleReaderTest` checks rendering, page overflow, find, 200% text, dark
mode, marker alignment/following, and activity recreation; physical TalkBack/math speech acceptance is pending.

## Design reference

The SwiftUI screens under `ios/Hearful/Views/` are the product design reference.
Match their information hierarchy, screen names, and content; use native Material
components and Android navigation conventions. Following and episode screens use
plain lists; search opens from the toolbar; the reader uses system typography and
toolbar actions. Do not add marketing headings, subtitles, sample badges, or a
separate command-testing interface to those screens. Keep the sample disclosure
in Settings. Article rows have no overflow buttons: swipe toward the end to
save/remove, or toward the start in Saved to mark read/unread. Long-press menus
and TalkBack custom actions expose the same operations without requiring swipes.
Feed headers have a management menu beside the title, matching iOS. Signed-in
Manage sources lists primary and additional sources, their host or newsletter
type, and any update failures. It combines other followed publications (including
all their sources) and separates non-primary sources. The backend owns duplicate
article selection and shared progress. Unsubscribe removes the whole publication
from Following while preserving Saved, bookmarks, and active playback; subscribed
previews also offer Unsubscribe. Forwarded newsletters explain how to stop their
forwarding rule. Source addresses display only their host, never private URL tokens.
Signed-out samples retain the account-required explanation and fixed catalogue.
Add sources searches podcasts and library episodes, discovers feeds from websites,
and previews content before subscribing.
Settings links to Sign-in Methods for Apple and Google sign-in, connected provider status,
real account sign-out and deletion. Home screen and Quick Settings actions are
available; assistant library browsing and newsletters remain in progress. AI Data Sharing
can be reviewed, granted, or withdrawn in Settings.

## Settings parity

Playback speeds apply independently to podcasts and narrated articles; changing
an inactive content type never changes current playback. Existing shared-speed
preferences migrate lazily to both types. Changes from system media controls are
saved to the active content type as well.

The voice picker and renderer share one policy: only installed, offline Google
voices are offered. The automatic choice prefers an English UK voice. Explicit
selection is persisted by engine voice ID; a missing selected voice prompts a new
choice rather than silently changing it. Selection takes effect on the next
article start, including regeneration of cached narration from its text bookmark.
Voice previews use transient audio focus and stop when Settings leaves the
foreground. Voice downloads return to a refreshed catalogue.

Conversation settings persist Keep listening after replies and a 10, 15, 20, or
30-second follow-up wait. With TalkBack, each turn requires an explicit Listen tap
so spoken announcements cannot enter an automatically opened microphone.
Assistant browsing and automation depend on compatible Android system services,
as described below. Newsletter address management remains an upcoming checklist
item. Siri itself is iOS-only. Privacy/support links use the same destinations
as the Swift client.

## Deliberate prototype boundaries

Signed-in accounts load real feeds, latest episodes, saved articles, and saved
podcast positions using the existing API. Podcast playback streams the real
HTTPS audio URL and reports position on pause and every thirty seconds. Finished
status uses the existing played-state endpoint for both articles and podcasts.
The service stops and clears account playback when the session changes.

The sample repository and sample capture inboxes remain separate while signed out.
There is no automatic upload of sample content, preview progress, or sample URLs.
Account metadata/text currently lives in memory: a fresh launch needs a connection,
and there is no durable queue for offline account edits or progress uploads.
New saved links and confirmed shared content have their own durable queue. A
previously identified session can queue captures after an offline restart; a new
session must identify its account first. Podcast downloading and Gemini integration
remain future work. Backups and device transfers of preview preferences are disabled.

## Home screen shortcuts and Quick Settings

After opening Magpie, hold its app icon for Ask Magpie, Continue listening, Play
latest, and Saved articles. Settings → Home screen and Quick Settings can pin
these actions or a particular library item/show. Reading pins open the reader;
listening pins resolve and play that item; show pins choose the latest unfinished,
undismissed item. The launcher asks for confirmation before pinning when supported.
Targeted shortcuts contain only scoped identifiers, never credentials or article
text. They require the account that created them and cannot silently switch to
another account or the sample library. Account lookups use the existing episode
endpoint and do not replace the search currently displayed in Magpie.

Continue listening preserves the loaded player's current clock, or resolves the
last item stored under the current account. Closing the mini player preserves this
explicit continuation choice; completion clears it. Podcast media positions and
article text bookmarks remain separate. A pending shortcut has a bounded wait and
Cancel control. Changed accounts, explicit media controls, sleep expiry, and audio
disconnection prevent a late response from starting playback. Recreating an
activity does not replay its original shortcut intent.

Ask Magpie and Continue listening also have Quick Settings tiles. Android 13+
can show the native Add tile prompt from Settings; Android 12 users can add them
with Quick Settings → Edit. Tiles request device unlock before opening the app.
The Ask launcher shortcut, home-screen pin, and tile start listening once Magpie
is in the foreground and unlocked. Android microphone permission is still required;
denial leaves typed input available. TalkBack keeps the explicit Listen tap.
An installation-specific random proof, stored privately and excluded from backup,
is published only to the Android shortcut host and permission-protected tile.
Ordinary exported intents cannot authorize recording, even if they request it.
The launch is consumed once; backgrounding, recreation, closing, typing another
request, and account changes invalidate pending permission replies. Returning to
the app never reopens the microphone automatically. Missing offline recognition
still produces the existing capability explanation without a network fallback.
Android 14+ uses the PendingIntent tile launch API; Android 12–13 use the guarded
legacy overload because the replacement is unavailable there.

Trusted Android media clients can browse Latest, Saved, and followed shows, search
the account library, and prepare or play an item through Magpie's playback service.
Both Media3 browsers and legacy platform browsers are supported. Browsing exposes
metadata and scoped IDs, without loading article text or exposing playback URIs.
Search does not replace the search displayed in Magpie. Folder IDs are invalidated
when accounts change; unrelated apps without Android media access are rejected.

Preparation resolves the account item and its bookmark, and renders article audio
on device when necessary. It stays paused until the client sends Play. Search can
select a named episode or the latest unfinished item from a followed show; an empty
playback search selects Latest. Controls from another media client, cancellation,
account changes, sleep expiry, and audio disconnection invalidate pending preparations.
Cancelled or failed preparation also suppresses the requester's queued Play,
preserving the previous item's paused position until a fresh explicit Play.
Podcast clocks and article text bookmarks remain separate. Arbitrary URIs and
multi-item queues are unsupported.

On Android 16 devices with a compatible AppFunctions metadata indexer, Magpie
also publishes structured AppFunctions for
listing followed shows, finding library items, and checking listening status.
Discovery follows account sign-in state; every invocation also checks the account
independently. Searches support show, unheard, duration, and result-count filters
against up to 100 candidates. Unknown durations are excluded only when a duration
ceiling is requested. Results contain scoped IDs and metadata, without article
text, credentials, or playback URLs. Account changes discard pending results;
caller cancellation stops the pending lookup. Status reads the existing service
player without starting playback. Devices below API 36 keep the service disabled.
Platform integration is verified on the API 36.1 emulator. The original API 36
image does not register the current schema; these actions are unavailable there.
Run `AppFunctionsTest` on an API 36.1 or newer emulator; it explicitly skips older
images. This is separate from the app's Android 12 minimum. The KSP compiler
generates the permission-protected service and schema from the
annotated Kotlin functions; generated files are not committed.

Structured playback actions can pause, skip, seek, set/undo speed, set/cancel a
sleep timer, play an item, continue listening, and play Latest or a followed show.
They use the same playback service and confirm its actual state. Play waits for
both active audio and foreground-service ownership; Android background-start
denial returns a one-use action to open Magpie for the selected, account-scoped
item. A pending start is cancelled by caller disconnection, account changes, or
independent controls. Stale item/show IDs are rejected before interrupting audio.
Local controls do not wait for unrelated library refreshes. Speed undo expires
after ten minutes and preserves later changes. Sleep durations round up to whole
minutes; podcast and article speed preferences stay separate. Rendered article
positions remain local text bookmarks.

Structured filing marks an explicit or current item played/read, dismissed, or
restored through the existing account action API. Library Undo reverses the last
reversible filing or subscription action; speed Undo remains a separate local
action. These typed requests do not use AI or require AI consent. The shared
account coordinator rejects overlapping changes, retains original request IDs
after uncertain failures, and keeps confirmed receipts until local reconciliation
finishes. Retrying a current-item request retains its original target even if
playback has changed. Pending requests and receipts clear on account changes.
After checking a stopped or unconfirmed request, a caller can explicitly request
a new change; normal retries never silently repeat a potentially completed action.
The player drains older podcast progress before a server mutation, applies filing
and restored text bookmarks through the same voice playback coordination, and
leaves uncertain results paused. Independent controls and caller cancellation
cancel the original request without resuming old audio. Network cancellation
closes the connection; no account credentials follow redirects.
An uncertain podcast clock also stays off the server when the user switches to
another item, until the corresponding result or a new item state is confirmed.
Retry context and these progress guards are in memory; durable recovery across
process death remains part of the offline/progress work in checklist item 11.

Assistant navigation can open Latest, Following, Saved, Now Playing, Shortcuts,
an item, or a followed show. Returned actions are immutable and one-use; the user
opens them to navigate without starting audio or microphone capture. Generic
screens remain available before sign-in. Account-bound actions are checked again
when opened and when the screen consumes the route. Removed shows are rejected,
and opening an item or show preserves ongoing playback.

Free-form assistant requests use the same account conversation as Ask Magpie.
Whole playback, speed, sleep, and speed-Undo commands run on device, including
before sign-in. Library Undo uses the typed action API without AI consent. Other
library requests require sign-in and the account's existing AI permission. The
adapter returns questions for the assistant to ask, and subsequent answers share
conversation history with the app. It confirms actual service playback before
announcing a start; Android background-start denial returns an action to open the
selected item instead.

Missing permission, a twenty-second request deadline, or an unconfirmed result
returns a one-use action to continue the original text in Ask Magpie without
starting the microphone. The intent contains an opaque capability, with the text
stored privately in memory for up to ten minutes. Recovery retains the original
request ID and confirmed receipt; checking a confirmed result does not repeat the
server mutation. Concurrent library requests cannot take over each other's conversation. Explicit
player controls remain available to interrupt a pending request. Caller cancellation, account changes, and independent player
controls stop pending work using its original account and leave uncertain audio
paused. Speed Undo is shared across the app and assistant, expires after ten
minutes, and preserves later manual changes. These conversation receipts and
handoffs do not survive process death; durable recovery remains in item 11.

Subscription actions remain part of checklist item 8. Google describes AppFunctions/Gemini integration as an
experimental private preview; launcher/tile availability does not establish
Gemini support or phone acceptance.

## Ask Magpie

Listen (or an Ask shortcut) asks for microphone permission and uses Android's on-device recognition
service, with an English (United Kingdom) model. Capability checks distinguish
missing, downloadable, and pending models; downloads require an explicit action.
There is no network recognition fallback. Recognition, spoken replies, and article
narration remain on device. Audio recordings are not retained. Typed requests are
available when the microphone or offline model is unavailable.

Local playback, speed, undo-speed, sleep-timer, and end-conversation commands work
without an account or AI permission. Library requests use the existing account
AI consent and command-stream contracts. Partials are captions; only final
recognition text becomes a command. Conversation context is kept in memory and
cleared across accounts. Interrupted requests retain their original ID for
Check previous request, avoiding a second server mutation.

The playback service pauses audio for a conversation and owns its resume decision.
Spoken replies finish before new playback or follow-up capture. Closing or
backgrounding the screen stops speech and recognition. Account changes, explicit
media controls, sleep expiry, and a disconnected audio route invalidate the old
resume decision. An uncertain remote result leaves playback paused until the
user checks the original request or explicitly resumes. Server filing receipts
never resend mutations or report an old
clock over a newly completed episode. The final compound playback choice starts
only after the other confirmed effects have been applied.

Article rendering currently completes before playback starts, with a 30,000
character guard and a timeout per chunk. Only the current rendered article is
retained; rendering files are private disposable cache data. This establishes
an audio baseline, not the final latency strategy. Measure time to first audio,
chunk transitions, and battery on the Pixel before choosing incremental rendering.

Article bookmarks contain the immutable content version and a **UTF-16 offset**
into the exact input text. For now, resume repeats the start of the current chunk.
The visual reading marker uses word timings when the voice supplies them; durable
resume remains at the chunk boundary. Podcast bookmarks use actual media milliseconds. Article positions are **never** written
to the backend's existing `position_seconds` field. A future cross-platform API
change must preserve the frozen released Swift clients.

On a fresh process, the last sample podcast is restored paused. A last-read article
is offered in the UI and regenerated from its bookmark on explicit Play. Full
system-initiated playback resumption after process death is future work.

## Verification and next device checks

JVM tests cover Unicode-safe bounded chunking, cross-voice bookmark mapping,
changed-content rejection, WAV metadata/padding, continuous timelines, truncated
files and incompatible formats. Emulator tests cover navigation, toolbar and reader
search, saved-article filing and restoration, separate-speed migration and
playback, selected-voice preview/persistence/narration, 200% text/dark theme, activity recreation, service playback after the
activity stops, seek and speed, and either article playback or the specific
missing-offline-voice explanation. `AppearanceTest` writes screenshots to Gradle's
additional-test-output directory when supplied, otherwise the app's private
`files/screenshots/` directory. GitHub Actions runs the compile, JVM tests and lint
gate; the emulator suite is currently a local check.

The emulator tests do not certify audible quality, microphone behaviour,
Bluetooth routing, TalkBack speech arbitration, battery use, or long screen-off
sessions. On the Pixel, verify those first, then an incoming call, interruption
recovery, and process-death resume. Borrow a Samsung before broad release.

The next functional work includes persistent offline account caching, durable
progress synchronisation, and
microphone/confirmation/TalkBack coordination.
Keep AppFunctions an optional adapter over the same action layer.

Following has a leading Add sources action. While signed in, typing searches the
podcast directory and account episodes; pasting a website or feed address offers
feed discovery. Multiple feeds require a choice, and a single feed opens its
preview. Preview episodes can be read or played before subscribing. Subscribe
updates Following only after server confirmation. Searching the web for a
publication is a separate, explicit AI action with account consent. Settings
provides review and withdrawal of that permission. Failed directory lookups keep
successful library matches available. Old queries, closed screens, and changed
accounts cannot restore stale discovery results. While signed out, addresses
stay in a separate local inbox and never become simulated subscriptions.

## Accounts and linked sign-in

Settings → Sign-in Methods opens the account screen. Apple uses a browser Custom
Tab with a backend code exchange and private app completion proof. Google uses
Credential Manager. Both produce a Magpie session encrypted using Android
Keystore with the API server as authenticated data.
A token saved for one server cannot be replayed by changing the build's server.
Cancellation leaves the account unchanged. Sign-out forgets the local session
immediately and attempts server revocation; account deletion requires confirmation
and only clears the session after the server confirms deletion.

Existing Apple users can sign in directly on Android when the backend's Apple
Services ID is associated with the iOS App ID. Either provider can be connected
from an existing account on either platform. Android retains encrypted pending
Apple attempts across process recreation, offers cancellation and retry, and
rejects expired or mismatched attempts. The browser return carries no credentials.
Both connected providers are listed on Android. Accounts already created
separately are not merged; the server returns a conflict without moving data.

Debug builds default to the registered Google server client and staging backend.
The local debug signing certificate is registered; other machines need their own
fingerprint added. `MAGPIE_GOOGLE_SERVER_CLIENT_ID` and `MAGPIE_ACCOUNT_API_URL`
Gradle properties override these defaults, including empty values to disable them.
Release defaults remain blank until a release signing certificate is registered.
The new backend must be deployed before either sign-in flow can complete. See [setup and acceptance checks](../docs/sign-in.md).
Signing in replaces the sample catalogue with the account library. Samples and
local capture inboxes are never attached automatically. Item/bookmark keys include
the server and account identity, and late replies cannot repopulate a signed-out
account. See [account-library implementation](../docs/android-library.md).

## Incoming sharing and browser capture

`ShareActivity` accepts `ACTION_SEND` with `text/plain` or `text/html`. It reads
`EXTRA_TEXT` (or a single plain-text/web-URI ClipData item), optional
`EXTRA_SUBJECT`/`EXTRA_TITLE`, and `EXTRA_HTML_TEXT`. It requires one unambiguous
HTTP(S) URL without credentials. Multiple links, arbitrary content/file URIs,
unsupported types, and payloads over 2 MB UTF-8 are rejected with an explanation.
Shared HTML is previewed as plain text; it never executes in the share screen.

Capture page is an explicit HTTPS browser action. It does not access the sending
browser's tab or cookies. The user can authenticate to a publisher in Magpie's
WebView, then choose Preview article. Extraction excludes hidden content and
uses the existing iOS article identity/ambiguity checks. It falls back to a link
when extraction is uncertain. Navigation during capture invalidates its reply.
The WebView has no native bridge, app authorization headers, file/content access,
third-party cookies, mixed content, downloads, or website permission grants.
Certificate errors are rejected. Website cookies/storage remain in Magpie's
WebView profile, separate from Chrome; physical publisher-login acceptance is
still required. A browser preview survives ordinary Compose updates; activity
recreation reloads its original URL. Process death returns an unconfirmed capture
to the original share for fresh review instead of restoring HTML in a Bundle.

Confirmation queues the original URL, title, HTML, content format, timestamp,
and replacement intent under the current server/account owner. A changed account
requires review again. Captures use the existing `/saved/replace` contract,
including the iOS warning that changed text resets listening. Each confirmed
capture keeps its own queue ID and upload order. This preserves an earlier offline
HTML copy if a later link-only capture fails, and an older in-flight acknowledgement
cannot remove the new content. Legacy URL-only
queue rows remain readable. Opening Magpie navigates to Saved and starts normal
foreground preparation; resuming an already-open app also checks its queue; closing the share leaves accepted content on disk.

`IncomingSharingTest` covers confirmation, cancellation, repeated intent delivery,
activity recreation, disk persistence, offline failure/retry, account changes,
queue replacement races, real WebView extraction, invalid content identity,
and 200% text/dark appearance. These use isolated accounts and page fixtures.
