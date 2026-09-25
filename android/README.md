# Magpie for Android

A native Kotlin / Jetpack Compose client. As on iOS, the app opens to sign-in
until a session exists, then loads the account library. The built-in sample
library remains only for instrumentation tests (`MagpieTestApplication`), which
use it without a backend or network connection; a test can set `requireSignIn`
to exercise the sign-in gate. Open this `android/` directory in Android Studio.
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
Use an **API 36.1 or newer** image for the full instrumentation suite: assistant
integration tests need its AppFunctions metadata indexer, which API 36 lacks.

The built-in Kotlin compiler and Compose compiler plugin are both pinned to
**2.4.20**, matching the Kotlin 2.4 libraries used by Coil **3.6.2**. Keep those
compiler versions aligned when upgrading image-loading dependencies.

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
refuse physical-device installs. They never uninstall the app or erase its data.

A USB-connected phone with USB debugging enabled has its own commands, which never
select an emulator:

```sh
make android-phone            # build debug, update the existing install, launch
make android-phone-staging    # the same, explicitly against staging (the debug default)
make android-phone-production # the same debug build against production
make android-phone-screenshot # save a phone PNG under build/android-artifacts/
make android-phone-logs       # save logs from Magpie on the phone there
```

They choose the only connected phone, or `ANDROID_SERIAL=serial` from `adb devices`.
Installs update in place, so the account and data survive. Sessions are bound to
their server, so switching backend signs the app out. Production sign-in needs a
production deployment that includes Android sign-in; see [sign-in](../docs/sign-in.md).

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
Compose tests use the [v2 test APIs](https://developer.android.com/develop/ui/compose/testing/migrate-v2).
These queue composition coroutines; use `waitForIdle()` or `runOnIdle` before
asserting on asynchronous UI changes.
Espresso is explicitly pinned to 3.7.0: older versions pulled in by Compose
reflect on `InputManager.getInstance`, which is absent on the API 36.1 emulator.
The [AndroidX Test release notes](https://developer.android.com/jetpack/androidx/releases/test#espresso-3.7.0)
document the fix to use the system service instead.

Reports are under `android/app/build/reports/`: `tests/testDebugUnitTest/`,
`androidTests/connected/debug/`, and `lint-results-debug.html`. Raw test XML is
under `android/app/build/test-results/` and `outputs/androidTest-results/`.
Check the XML test counts as well as the build result: a crashed emulator system
process can leave zero executed tests even when Gradle reports success. If Android
is globally unresponsive, close the development emulator and cold-start the same
AVD without wiping its data; verify the installed CLI help for the startup options.
The same recovery applies when instrumentation reports `UiAutomationService ...
already registered!` after restoring a snapshot. Use
`./scripts/android-dev.sh cli emulator start --cold AVD_NAME` after stopping it.
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

- Following, Latest, Saved, source detail, and a rich article reader. As on iOS,
  Following's search filters show names on the device; Add sources searches episodes.
- Article/episode toolbars with playback, original-page opening, Android sharing,
  find, and an Ask Magpie entry point. Opening the original and sharing appear only
  when the article has a web page, as on iOS. The byline links to a followed show.
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
  plays a quiet completion tone with a short vibration, and clears the player. As on
  iOS, a running sleep timer keeps counting and does nothing if nothing is playing. Saved
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
  Saved articles offer Capture page and Replace saved text in their long-press menu
  (as iOS does for Replace), and Capture page beside Retry when the server cannot read a page.
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
  pause/resume, and playback speed from 0.75× to 2× (as on iOS; spoken requests may still set 0.5–3×).
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
in Settings. Article and episode rows have only a play button, with no overflow
button. Match iOS filing gestures: swipe toward the end to dismiss in Latest and
Saved, and toward the start to mark read/played or restore an item. Publication
rows do not offer the leading dismissal swipe. Long-press menus and TalkBack
custom actions expose filing and article saving without requiring swipes.
Feed headers have a management menu beside the title, matching iOS. Signed-in
Manage sources lists primary and additional sources, their host or newsletter
type, and any update failures. It combines other followed publications (including
all their sources) and separates non-primary sources. The backend owns duplicate
article selection and shared progress. Unsubscribe removes the whole publication
from Following while preserving Saved, bookmarks, and active playback. As on iOS it
is in the show's menu (with progress on the menu button), not in Manage sources, which
closes with Done; subscribed previews also offer Unsubscribe. Forwarded newsletters explain how to stop their
forwarding rule. Source addresses display only their host, never private URL tokens.
Signed-out samples retain the account-required explanation and fixed catalogue.
Add sources searches podcasts and library episodes, discovers feeds from websites,
and previews content before subscribing.
As on iOS, Settings' Account section holds Sign-in Methods (one section per provider,
marked Connected or offering Continue), Sign Out, and Delete Account with confirmation.
Home screen and Quick Settings actions are available alongside assistant library browsing
and newsletter management. Settings offers "Turn Off AI Data Sharing" (with confirmation)
or "Review AI Data Sharing", as on iOS. Without permission, the voice sheet says what still
works and offers "Enable other voice requests"; a request needing AI is explained aloud
rather than interrupted by a prompt. Requests handed over from outside still offer consent.

## Settings parity

Playback speeds apply independently to podcasts and narrated articles; changing
an inactive content type never changes current playback. Existing shared-speed
preferences migrate lazily to both types. Changes from system media controls are
saved to the active content type as well. Spoken replies and newsletter addresses
use the article speed, read again for each reply.

The voice picker and renderer share one policy: only installed, offline Google
voices are offered. The automatic choice prefers an English UK voice. Explicit
selection is persisted by engine voice ID; a missing selected voice prompts a new
choice rather than silently changing it. Selection takes effect on the next
article start, including regeneration of cached narration from its text bookmark.
Voice previews use transient audio focus and stop when Settings leaves the
foreground. Voice downloads return to a refreshed catalogue.

Conversation settings persist Keep listening after replies and a 10, 15, 20, or
30-second follow-up wait. With TalkBack, each turn requires an explicit double tap
on the microphone so spoken announcements cannot enter an automatically opened microphone.
Assistant browsing and automation depend on compatible Android system services,
as described below. Siri itself is iOS-only. Privacy/support links use the same destinations
as the Swift client.

## Newsletters

Settings shows the signed-in account's newsletter address, with copy/share actions
and offline read-aloud or letter-by-letter spelling. Speaking pauses the shared
player and resumes it only after speech ends; independent playback controls or an
account change cancel speech without restarting audio. Leaving Settings stops the
readout. Address speech never starts the microphone or requires AI permission.

Pending senders appear at the top of Latest, as on iOS. Follow adds their messages to the
library; Block asks for confirmation before deleting their messages and dropping
future emails. Requests are serialized and scoped to the current account session.
Late refreshes cannot restore an approved sender, and failed writes keep the row
available for retry. Account changes clear the address, sender list and signup
result; old rows cannot act on the next account.

When website feed discovery fails, Sign up by email explicitly asks the site to
send its newsletter to the Magpie address. The result distinguishes a submitted
request from a signup that needs finishing by hand, with address copy/share for
the latter. Signup uses the existing backend's sixty-second allowance and needs
no AI consent. No website signup is submitted just by searching for feeds.

## Deliberate prototype boundaries

Signed-in accounts load real feeds, latest episodes, saved articles, and saved
podcast positions using the existing API. Podcast playback streams the real
HTTPS audio URL and reports position on pause and every thirty seconds. Finished
status uses the existing played-state endpoint for both articles and podcasts.
The service stops and clears account playback when the session changes.

The sample repository and sample capture inboxes remain separate while signed out.
There is no automatic upload of sample content, preview progress, or sample URLs.
Account metadata/text now has a private durable cache, and guarded podcast
positions have an account-scoped retry journal. Shared article bookmarks work in
both native players, and structured assistant requests have durable recovery.
New saved links and confirmed shared content have their own durable queue. A
previously identified session can queue captures after an offline restart; a new
session must identify its account first. Podcast downloading is not implemented.
AppFunctions are implemented and tested through the Android platform; full Gemini
acceptance needs Google preview access. See the [acceptance matrix](../docs/android-acceptance.md). Backups and device transfers of preview preferences are disabled.

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
denial offers Open settings. TalkBack keeps an explicit tap on the microphone.
An installation-specific random proof, stored privately and excluded from backup,
is published only to the Android shortcut host and permission-protected tile.
Ordinary exported intents cannot authorize recording, even if they request it.
The launch is consumed once; backgrounding, recreation, closing, starting another
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
positions use guarded shared text bookmarks when supported, with local bookmarks for older servers.

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
Request recovery and guarded podcast progress persist across restart. Recovered
receipts reconcile their matching filing guards without replaying historical audio
or overwriting a later listening choice.

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
minutes, and preserves later manual changes. Free-form requests and their receipts
now survive process death; the one-use navigation handoffs remain in memory. After
a restart, open Ask Magpie to review unfinished requests. Structured filing/Undo
requests use the same journal and recovery controls, preserving their original
route, item and request ID. They can be checked or dismissed without AI consent.
An interrupted current-item action retains its original item when playback changes;
starting a new change keeps the older request available for review.

`followPublicationUrl` discovers website/feed addresses without AI. A single feed
is followed directly; multiple feeds return named choices without subscribing.
The assistant asks the user to choose and passes the unchanged choice ID with the
original website. Choices are checked against fresh discovery and bound to the
account and session. Results contain the canonical, account-scoped followed show;
already-followed feeds and retries after a lost reply are recognised without
creating another subscription. `getNewsletterAddress` returns the current signed-in
account's address without AI permission; it does not send a signup request.

Google describes AppFunctions/Gemini integration as an
experimental private preview; launcher/tile availability does not establish
Gemini support or phone acceptance.

## Ask Magpie

Ask Magpie matches the iOS voice sheet: a half-height sheet whose large microphone
area is one control, with a status caption and the conversation beneath it. The
in-app microphone buttons open it straight into listening; tapping again finishes
speaking or interrupts. There is no typed input. TalkBack users start each turn
with a double tap, untrusted shortcuts never start the microphone, and unfinished
requests are reviewed separately. Speech-model, permission and recovery
controls appear only when relevant.

As on iOS, each moment has a cue: a tick when the sheet opens, a tone and click when
a request starts, a distinct tone with a strong vibration once the microphone is live,
a tone when speech is captured, a tone if a reply takes over 8 seconds, a tone when a
follow-up ends quietly, and an error vibration. Failures are spoken as well as shown.
Clarifying questions allow at most three follow-ups; answering one by tap keeps the
conversation going. Pause, resume and skip end the exchange but leave the sheet open.

Opening asks for microphone permission and uses Android's on-device recognition
service, with an English (United Kingdom) model. Capability checks distinguish
missing, downloadable, and pending models; downloads require an explicit action.
There is no network recognition fallback. Recognition, spoken replies, and article
narration remain on device. Audio recordings are not retained.

Local playback, speed, undo-speed, sleep-timer, and end-conversation commands work
without an account or AI permission. Free-form library requests use the existing account
AI consent and command-stream contracts; explicit library Undo uses the typed
action route without AI. Partials are captions; only final
recognition text becomes a command. Live conversation history stays in memory and
clears across accounts. Unfinished free-form requests retain their original text,
ID, target, recent context and any confirmed receipt in private storage excluded
from backup. They are saved before dispatch and before local reconciliation.

"Check saved requests" (offered when a change could not be confirmed) lists each unfinished request, including after a restart; the microphone sheet itself does not, as on iOS. Saying "did that work?" checks the last one. Check this request uses
the original ID/body; an already-saved receipt needs no repeated command. Recovery
refreshes current library state rather than applying an old filing receipt over
newer changes, and reports historical playback results without restarting audio or
changing speed. A confirmed Dismiss request cancels unfinished server work, refreshes
the library, releases its progress guard, and removes that recovery record; it does
not undo completed changes. Cancellation, storage or connection failures retain
the record. Dismissal works without AI consent. Signing out clears the account's
journal. Loading recovery does not start the microphone or send a command.

The playback service pauses audio for a conversation and owns its resume decision.
Spoken replies finish before new playback or follow-up capture. Closing or
backgrounding the screen stops speech and recognition. Account changes, explicit
media controls, sleep expiry, and a disconnected audio route invalidate the old
resume decision. An uncertain remote result leaves playback paused until the
user checks the original request or explicitly resumes. Server filing receipts
never resend mutations or report an old
clock over a newly completed episode. The final compound playback choice starts
only after the other confirmed effects have been applied.

Article narration prepares the resume passage first, then synthesizes passages
as Media3 needs them. Long articles no longer have the 30,000-character guard.
The whole article remains one media item, including for assistant and system
controls. Its duration initially includes estimates for unprepared passages;
measured audio durations replace those estimates without changing text bookmarks.
The private disposable cache keeps at most six completed passages unless a file
is still being read, plus the passage currently being prepared. Seeking can
regenerate an evicted passage. Cancellation, replacement and account changes
close the voice and discard its temporary audio. A later synthesis failure stops
playback without marking the article finished. Each passage has a voice timeout.
Measure audible transitions, startup latency and battery on the Pixel separately.

Article bookmarks contain the immutable content version and a **UTF-16 offset**
into the exact input text. For now, resume repeats the start of the current chunk.
The visual reading marker uses word timings when the voice supplies them; durable
resume remains at the chunk boundary. Podcast bookmarks use actual media milliseconds. Article positions are **never** written
to the backend's existing `position_seconds` field. Shared article progress uses
the guarded text-bookmark contract documented in `docs/progress-sync.md`.

Opening the app restores the remembered account or sample item paused. Podcasts
resolve current account metadata and position; articles show their title without
fetching text or starting the speech engine until explicit Play. Dismissing the
player disables automatic restoration while preserving explicit Continue listening.
Completed/unavailable items and previous accounts cannot reappear.

Media3 playback resumption and the media-button receiver let system Play resolve
the remembered item when the service is recreated. Metadata-only system queries
use the current cache without fetching text or preparing audio. New playback,
Pause, account changes and caller cancellation invalidate pending work. Emulator
service-recreation coverage is separate from physical-device process-death,
lock-screen and Bluetooth acceptance; see the [acceptance matrix](../docs/android-acceptance.md).

## Offline account library

Following, Latest, Saved, opened feed lists and fetched article text/HTML are saved
in app-private storage outside disposable caches and excluded from backup. A known
session restores only its server-bound account snapshot before refreshing. Failed
refreshes retain the restored content with a retry message; feed browsing and
search retain previously known matching items. Search while offline covers only
items this device has already seen. Podcast audio still needs a connection.

Saved article content IDs and text versions survive restart. Confirmed filing,
removal, replacement and source changes update the snapshot; replacing text cannot
revive the previous copy after restart. Signing out clears that account's snapshot
and immediately replaces its UI with samples. Late reads/writes cannot publish
another account's content. Corrupt or incompatible snapshots are discarded; a disk
write failure warns about offline availability without retrying a server mutation.
Storage uses serialized [AtomicFile](https://developer.android.com/reference/android/util/AtomicFile)
replacement and performs file I/O away from the UI thread.

Podcast progress uses an account-scoped durable journal when the server supplies
a comparison token. Playback saves locally every three seconds and on pause or
completion, retains exact requests after lost replies, and uploads later samples
only after acknowledgement. Startup and periodic retries run while the app process
is alive. Newer server filing/progress blocks the old playback session instead of
being overwritten. Sign-out clears the journal. Voice filing guards are persisted
before a server change; unresolved guards survive restart. See
[the progress protocol](../docs/progress-sync.md).

Article playback now uses the shared UTF-16 bookmark contract when advertised by
the server. Explicit Play refreshes the selected text and remote bookmark, falling
back to the matching cached snapshot offline. Durable exact requests survive
restart; newer filing or changed text blocks the old playback session. Completion
uses the same guarded report, and voice filing holds and sign-out cover both
article and podcast journals. Locally rendered article seconds never use the
media-position API. The Swift player consumes the same text coordinate, independently
of voice speed or estimated playback duration.

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

Item menus on Latest, publication lists, search results and the reader offer
read/unread or played/unplayed, individual dismissal, and restoration to Latest.
Rows use long-press menus and TalkBack actions alongside the iOS filing swipes.
As on iOS, the reader has no filing menu.
Signed-in changes use the same durable typed requests as assistant actions,
without AI consent. A lost reply can be retried or checked in Ask Magpie after
reopening the app. Filing the active item stops its old progress; marking it
unread/unplayed resets its bookmark, while Undo retains the previous bookmark.
Sample changes stay local and are saved before being acknowledged.

Latest groups unfinished listening items under Continue listening without
duplicating rows. Library rows show live playback state, podcast time remaining,
text-based article progress and finished status. Publication dates appear in lists
and the reader; publisher artwork appears in lists, publication headers, both
players and system media metadata. Optional metadata survives account caches and
request recovery, with placeholders for missing or unavailable images.

All sixteen functional areas in [the parity checklist](../docs/android-parity.md)
are implemented. Physical microphone, confirmation, TalkBack, Bluetooth and
long-session audio acceptance remain separate from emulator verification.
Keep AppFunctions an optional adapter over the same action layer.

Following has a leading Add sources action. While signed in, typing searches the
podcast directory and account episodes; pasting a website or feed address offers
feed discovery. Multiple feeds require a choice, and a single feed opens its
preview. Preview episodes can be read or played before subscribing. Subscribe
updates Following only after server confirmation. Searching the web for a
publication is a separate, explicit AI action with account consent, offered (as on
iOS) only when nothing else matched. Results arrive as you type, in the iOS order
(library, its episodes, the podcast directory, the web), filtered by All, Sources or
Episodes; a pasted address shows an "Open podcast or feed" row. Settings provides
review and withdrawal of that permission. Failed directory lookups keep
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
Release builds default to production and require private signing inputs and an
explicit certificate fingerprint before they can build. No release key or Google
Play app has been created. See [release preparation](../docs/android-release.md)
and [sign-in acceptance](../docs/sign-in.md); staging verification does not establish
production or Play-distributed sign-in.
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

## Reliability diagnostics

Settings → Privacy & Support → Share app diagnostics controls voice-attempt and
crash/freeze summaries. It defaults to enabled; turning it off immediately stops
new reports and clears pending diagnostics without affecting the library or
playback. Signed-out sample sessions never report.

Spoken requests record coarse outcomes, capture/response timing, local transport
or sleep actions, and whether TalkBack was active. The request and its summary
share a trace ID when a backend command was sent. No transcript, audio, article
content, exception message or raw stack enters a diagnostic payload. Android
recognition does not expose an initial audio-buffer time, so that field is omitted.

Reports use the existing authenticated `/events/voice` and `/events/diagnostic`
contracts. A private queue outside Android backups retains at most 50 reports per
account for 30 days, retries after connectivity returns, and clears on sign-out
or opt-out. Session checks prevent delayed requests from using a different
account's credentials. Recent acknowledgements prevent a recovered crash from
being queued twice after a restart.

Android system process-exit records supply Java/native crash and fatal ANR
summaries on the next launch. A random process marker connects them to a private
account/session record; the OS never receives the account ID or token. Only a
matching account and credential can submit the previous exit. A separate check
records foreground main-thread freezes lasting at least five seconds, after the
thread responds again; background, screen-off and debugger sessions are excluded.
These are best-effort summaries: they do not collect stack traces or replace
physical-device performance and crash acceptance.
