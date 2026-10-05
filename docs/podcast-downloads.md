# Podcast downloads

Episode audio can be kept on the phone so it plays with no connection. Article
text was already kept offline (see `offline-reliability-investigation.md`);
this covers podcast audio only. iOS and Android follow the same rules; the
Android section below lists where they differ.

## Behaviour

- **Manual downloads.** The download button on an episode's page, the
  "Download" swipe action on episode rows (in VoiceOver's Actions rotor), the
  capsule in the full player, "Download unplayed episodes" in a show's ⋯ menu
  (newest five), and the voice commands "download this" / "remove this
  download" for whatever is loaded in the player. A manual download is never
  removed to make room while it is unheard.
- **Automatic downloads.** On by default: the newest unplayed episode of each
  followed show (1–3, configurable), taken from Latest. An automatic download
  that drops out of Latest (played, dismissed, cleared) is removed. Automatic
  downloads never displace an unheard episode; they only make room by removing
  finished ones. Refreshed at launch, on foregrounding and when the connection
  returns, at most every 15 minutes.
- **Storage limit.** 1, 2 (default), 5 or 10 GB, or no limit. When room is
  needed, finished episodes go first (oldest first), then automatic downloads
  (oldest first). Lowering the limit applies immediately.
- **Going over the limit.** A manual download that would exceed the limit
  after removing everything removable asks first: a dialog for a tap, a spoken
  yes/no question for a voice request. A download is refused outright when the
  phone itself would be left with less than 500 MB free.
- **Mobile data.** With "Use Wi-Fi only" on (default), automatic downloads
  wait for Wi-Fi, and a manual download on mobile data asks: Download Now, Wait
  for Wi-Fi, or Cancel. With it off, manual downloads just start.
- **Finished episodes** are removed a day after she finishes them, or
  immediately if space is needed. Marking an episode unplayed keeps it.
- **Sign-out and server changes** delete every download. Transfers started for
  the previous account are discarded when they land (the manifest's epoch).

Size checks use an estimate of 128 kbit/s × the feed's duration (50 MB when
unknown); the measured size replaces it once the file arrives.

## Implementation

- `ios/Hearful/Downloads/DownloadModel.swift` — settings, records, the pure
  `DownloadPolicy` rules and the on-disk `DownloadStore`
  (`Application Support/Downloads`, excluded from backup, with a JSON manifest
  that keeps an `Episode` snapshot so downloads list and play offline).
- `DownloadTransport.swift` — a background `URLSession`, so transfers continue
  while Magpie is suspended or closed. `HearfulApp` handles the relaunch via
  `.backgroundTask(.urlSession(...))`.
- `EpisodeDownloads.swift` — the main-actor controller used by the UI, voice
  and `AudioPlayer`, which plays the local file in place of the feed URL.
- UI: `Views/DownloadControls.swift`, `Views/DownloadsView.swift`
  (Settings → Downloads), the row status in `ShowDetailView.swift`'s
  `EpisodeMetadata`, and the swipe action in `API/EpisodeFiling.swift`.

No backend or API contract change was needed.

## Not yet done

- Voice requests that name other episodes ("download the next three episodes
  of In Our Time") need a new backend command action and a client capability
  flag, so released clients are not sent an action they cannot perform.
- Automatic downloads only refresh while the app runs; a `BGAppRefreshTask`
  would fetch new episodes overnight.

## Android

The same settings, limits, voice phrases and wording, in
`android/app/src/main/java/com/henrydashwood/magpie/data/EpisodeDownloads.kt`
(rules and controller, unit-tested in `EpisodeDownloadsTest`) and
`AndroidDownloads.kt` (platform pieces). Differences:

- **Transfers** use Android's system `DownloadManager`, which keeps going when
  Magpie is closed and supports a per-download "no metered network" rule for
  Wi-Fi-only downloads. Files go to app-specific storage
  (`Android/data/<package>/files/Podcasts`). Downloads she asks for show
  progress in the notification shade; automatic ones are silent
  (`DOWNLOAD_WITHOUT_NOTIFICATION`). Magpie polls the system's rows while
  anything is under way, and again on the next launch.
- **No request of its own.** The controller follows `AccountLibrary.state`:
  Latest decides automatic downloads, an item's `completed` flag marks it
  finished, and a different account owner or signing out clears everything.
- **Row actions.** Download / Cancel download / Remove download is in each
  episode's long-press menu and TalkBack actions (Android rows put actions
  there rather than behind a swipe). The episode page's toolbar shows the
  download button in place of "Open the original"; the full player and the
  show's ⋯ menu match iOS. Settings → Downloads lists everything with visible
  play, retry and remove buttons.
- **Voice.** "Download this" and "remove this download" are local commands. A
  spoken question waits two minutes for its answer, which also works when
  TalkBack ends the turn after the question.
- **Assistant (App Functions)** requests to download are answered with "Open
  Magpie to manage downloads", since they cannot ask for a yes.
