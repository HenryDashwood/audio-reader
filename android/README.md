# Magpie for Android

A native Kotlin / Jetpack Compose preview, runnable without a phone, account,
backend, or network connection. Open this `android/` directory in Android Studio.
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
  samples share their text. Ask explains that conversation is not yet connected.
- The same Ask Magpie control is available on Following, Latest, Saved, Settings,
  and feed pages, including during search. Browser links use Material's Open in new icon.
- Light/dark themes, scalable text, labelled controls, heading semantics, and
  scrollable layouts. Automated checks exercise 200% text; physical TalkBack
  acceptance is still required.
- Save/remove sample articles and file them under To read or Finished, persisted locally.
- Reaching the end of a podcast or narrated article records it as finished locally,
  plays a quiet completion tone, and clears the player and sleep timer. Saved
  articles move to Finished without reopening the screen. The completed player
  stays closed after recreation/relaunch; explicitly playing the item starts over.
- Clear Latest uses a confirmation dialog and persists the current item IDs as
  dismissed locally, without marking them played/read or changing Saved, feed pages,
  or playback bookmarks. New IDs remain eligible for Latest.
- Saved's + button captures web URLs in a separate durable local inbox. Pending links
  appear under To read, support search and removal, and survive app restarts.
  Article fetching/preparation and account sync are not connected yet.
- Separate persisted podcast/article speeds, an installed offline voice chooser,
  voice previews, and links to voice downloads, privacy, and email support.
- A native Material mini player with artwork/title, contextual Follow, play/pause,
  a Stop and close (×) button, and a decorative progress line. Controls have 48dp
  touch targets; narrow screens and large text give the title a separate row.
  Closing saves the bookmark, cancels pending narration and the sleep timer,
  stops/clears session media, and forgets the last item so the bar stays dismissed
  after recreation/relaunch. Explicit Play brings it back from the saved position.
- A bundled original sample recording, a mini player and full player, seek,
  pause/resume, and playback speed from 0.75× to 2×.
- A sleep timer beside playback speed, with the iOS choices of 5, 10, 15, 30,
  45, and 60 minutes, a rounded-up countdown, replacement, and cancellation.
  The playback service owns its monotonic deadline, so closing the player or
  backgrounding/recreating the activity does not reset it. Playback speed and
  pauses do not extend the timer. Expiry pauses audio, preserves the bookmark,
  cancels pending narration, and plays a quiet completion tone only if audio was
  playing. Timers clear when the service/process ends and are not restored after
  a restart. Voice timer commands await Android's voice integration.
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
changed, and live account/article fetching is still future work.

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
Feed headers have a management menu beside the title, matching iOS. Manage sources
shows the bundled source and explains the preview boundary; Unsubscribe is disabled
with an account-required explanation. Combining, separating, and unsubscribing
require a connected account rather than mutating the fixed sample catalogue.
Settings links to Sign-in Methods for Apple and Google sign-in, connected provider status,
real account sign-out and deletion. Conversation, assistant, newsletters, and
consent retain explicit unavailable states until their integrations exist.

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

Conversation timing, Android assistant integration, newsletter addresses, and AI
consent still require their corresponding Android integrations. The Settings sections make those boundaries visible. Siri itself
is iOS-only. Privacy/support links use the same destinations as the Swift client.

## Deliberate prototype boundaries

The sample repository supplies playable content; locally captured URLs stay in
their separate pending inbox until account and article processing are connected.
Apple and Google sign-in and account controls use the backend when configured (see
[sign-in setup](../docs/sign-in.md)); the library remains sample-only. There is no
live library loading, feed discovery, cloud progress reporting, incoming share
capture from other apps, podcast downloading, Gemini integration, or microphone
recording in this version. Internet access is used for HTTPS article images and embedded videos; the
manifest does not request microphone access. Settings identifies this as a sample library. Backups and device transfers of
preview preferences are disabled.

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

The next functional work is a backend-backed repository,
safe progress synchronisation, and microphone/confirmation/TalkBack coordination.
Keep AppFunctions an optional adapter over the same action layer.

Following has a leading Add sources action. Feed or website addresses are validated
and saved in a separate local inbox, listed as pending sources and removable from
that list. They never become Saved articles or simulated subscriptions. Feed
discovery, name search, and subscribing require the future account connection.

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
Signing in does not attach sample content or local preview bookmarks to a real
account. Live library loading is the next part of parity item 1.
