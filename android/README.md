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
make android-doctor  # Java, SDK, connected devices
make android-build   # compile the debug APK
make android-check   # compile, JVM tests, Android lint
make android-test    # Compose UI and Media3 integration tests on one running emulator
make android-run     # build, install over the existing emulator app, launch
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

## What works

- Following, Latest, Saved, source detail, local library search, and a text reader.
- Article/episode toolbars with playback, original-page opening, Android sharing,
  find, and an Ask Magpie entry point. Original-page opening requires a web URL;
  samples share their text. Ask explains that conversation is not yet connected.
- The same Ask Magpie control is available on Following, Latest, Saved, Settings,
  and feed pages, including during search. Browser links use Material's Open in new icon.
- Light/dark themes, scalable text, labelled controls, heading semantics, and
  scrollable layouts. Automated checks exercise 200% text; physical TalkBack
  acceptance is still required.
- Save/remove sample articles and file them under To read or Finished, persisted locally.
- Clear Latest uses a confirmation dialog and persists the current item IDs as
  dismissed locally, without marking them played/read or changing Saved, feed pages,
  or playback bookmarks. New IDs remain eligible for Latest.
- Saved's + button captures web URLs in a separate durable local inbox. Pending links
  appear under To read, support search and removal, and survive app restarts.
  Article fetching/preparation and account sync are not connected yet.
- Separate persisted podcast/article speeds, an installed offline voice chooser,
  voice previews, and links to voice downloads, privacy, and email support.
- A bundled original sample recording, a mini player and full player, seek,
  pause/resume, and playback speed from 0.75× to 2×.
- Media3 playback owned by a `MediaSessionService`, with system media controls,
  audio focus, unplug-to-pause, and playback independent of the activity.
- Google offline TTS rendered into short WAV chunks and assembled into **one**
  playable article. Preparation can be cancelled; missing offline voices produce
  an explicit explanation. No network TTS fallback is selected.

The sample WAV is an original Magpie introduction, generated with the Mac's
installed Alex voice. Its matching transcript is in `data/Library.kt`. It is
bundled so playback tests don't depend on a publisher's stream or a network.

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
Settings shows the account, conversation, assistant, and newsletter sections with
explicit unavailable states until their integrations exist; it does not present
fake sign-out, account deletion, or consent controls.

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

Conversation timing, Android assistant integration, newsletter addresses, sign-in,
account deletion, and AI consent still require their corresponding Android
integrations. The Settings sections make those boundaries visible. Siri itself
is iOS-only. Privacy/support links use the same destinations as the Swift client.

## Deliberate prototype boundaries

The sample repository supplies playable content; locally captured URLs stay in
their separate pending inbox until account and article processing are connected.
There is no Google sign-in,
live backend access, feed discovery, cloud progress reporting, incoming share
capture from other apps, podcast downloading, sleep timer, Gemini integration, or microphone
recording in this version. The manifest does not request Internet or microphone
access. Settings identifies this as a sample library. Backups and device transfers of
preview preferences are disabled.

Article rendering currently completes before playback starts, with a 30,000
character guard and a timeout per chunk. Only the current rendered article is
retained; rendering files are private disposable cache data. This establishes
an audio baseline, not the final latency strategy. Measure time to first audio,
chunk transitions, and battery on the Pixel before choosing incremental rendering.

Article bookmarks contain the immutable content version and a **UTF-16 offset**
into the exact input text. For now, resume repeats the start of the current chunk.
There is no word highlighting or exact within-chunk text/audio alignment. Podcast
bookmarks use actual media milliseconds. Article positions are **never** written
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

The next functional work is the account-linking flow, a backend-backed repository,
safe progress synchronisation, and microphone/confirmation/TalkBack coordination.
Keep AppFunctions an optional adapter over the same action layer.

Following has a leading Add sources action. Feed or website addresses are validated
and saved in a separate local inbox, listed as pending sources and removable from
that list. They never become Saved articles or simulated subscriptions. Feed
discovery, name search, and subscribing require the future account connection.
