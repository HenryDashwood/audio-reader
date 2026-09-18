# Offline reliability investigation

Investigated 18 September 2026, against the current working tree. The primary
review is iOS; Android comparisons below are source inspection only. Existing
uncommitted work was preserved. The findings below describe the original
behaviour. The implementation follow-up at the end records the subsequent fixes.

## Article text available to speech but missing from the reader

The reader and narrator both use `OfflineCache`, but independently decide which
copy to request, which cache key to write, and when to fall back to disk.
There is a concrete mismatch when an episode's metadata has no `contentID`, but
the text response supplies one:

1. A list contains episode 42 without a content version, for example a list
   loaded before that article was saved.
2. The text endpoint returns saved version 10. This is allowed by
   `backend/src/audioreader/routers/feeds.py:get_episode_text`: without an explicit
   version, it resolves the account's selected saved content.
3. `ArticlePlayer.load` stores the payload under `article-42-version-10.json`
   and updates its own episode metadata.
4. `ArticleTextModel.load(episodeID: 42)` still looks for `article-42.json`.
   Without the network, that reader cannot find the text the player just loaded.
5. Passing version 10 to the reader makes the existing local copy readable.

The reverse also exists: the reader writes a versioned response under the
unversioned request's key. A subsequent reader opened with version 10 looks in
the versioned slot and misses it. Updating the player's metadata does not
generally update every list and open reader; the reader specifically observes
Saved list replacements, not the player's resolved content identity.

Sources: `ios/Hearful/Views/ArticleView.swift:ArticleTextModel.load`,
`ios/Hearful/Audio/ArticlePlayer.swift:load`,
`ios/Hearful/API/OfflineCache.swift:Key`.

This provides a source-level explanation for text/audio disagreement; it does not
establish the cause of every incident on the physical phone. Even with matching
keys, the reader always requests the network first. Already running narration
can continue from memory while the reader waits. The reader also does not
retry when the player subsequently populates the cache.

Recommended first change: give reading, narration and Saved preparation one
article-content store. Persist the returned version under its canonical key,
and record the last resolved selection for requests without a version. Validate
episode identity and explicit version matches. Never choose an arbitrary older
version just because a requested version is unavailable. Keep text, HTML and
bookmark identity together, and notify consumers when a usable copy arrives.

## Other findings, in suggested order

| Priority | Current behaviour | Improvement |
| --- | --- | --- |
| High | Article text, Latest, Following and publication lists consult disk only after a network failure. A weak connection can hide usable local content behind a request. Starting article playback can also wait for pending progress uploads and a fresh selection request. | Show matching local content immediately, refresh separately, preserve visible content on refresh failure, and avoid making local playback wait indefinitely for sync. Reconcile remote bookmarks before changing an established local playback session. |
| High | `PlaybackRestore` persists only the episode ID and requires a fresh episode request. Offline relaunch leaves the player empty despite cached text and durable article bookmarks. Shortcut resolution also requires the server when no episode is already loaded. | Persist account-scoped last-played metadata, restore it with matching local text and the journal, then refresh remotely. Use the same resolver for shortcuts. |
| High | Saved downloads are best effort and silently swallow failure. A saved row is not proof its text is on the phone. `SavedLibrary.load` attempts pending uploads before loading the saved list; one slow upload delays the list, then missing text downloads run serially. | Hydrate Saved from disk first. Track per-article states such as waiting, downloading, available offline and failed. Use a bounded retry queue, make failures actionable, and separate capture uploads from list display. Confirm local persistence before reporting offline readiness. |
| High | The voice controller has local transport commands, but `VoiceSheet` first requires a fetched AI consent state. On an offline cold start `auth.user` remains nil, so even local commands are gated by “Checking your AI data-sharing choice…”. | Allow an explicitly local voice path with installed on-device recognition. Gate only requests that send data to the server on consent. Never infer consent or fall back to network recognition silently. |
| Medium | Modern article bookmarks have a durable journal with retries. Podcast and legacy article seconds in `PositionReporter` use `try?` uploads without a persistent retry queue. UI/cache notifications help locally, but a failed final position can be lost to the server and later overwritten by a refresh. | Add account-scoped durable podcast progress, with ordering and reconciliation so retries cannot undo a later deliberate mark-as-unplayed action. Reuse the article journal's principles; do not indiscriminately replay stale seconds. |
| Medium | Publication search deliberately fails offline instead of returning the entire unfiltered cached list. Saved search already works locally. | Filter cached publication items and label results “On this device”; explain that the full archive needs a connection. Do not present partial local results as a complete server search. |
| Medium | Mark read/unread, dismissal, saving an existing feed item and removing a saved item require successful network writes. A Safari capture can already be durably queued locally. | Extend queued local actions selectively, with pending status, Undo and conflict handling. Start with read/unread and dismissal. A saved feed item needs both durable intent and retained content if it is to work offline immediately. |
| Medium | Pending browser captures can contain HTML on disk, but the Saved pending row only offers removal. They remain unreadable until server preparation. | Where a capture contains sufficient text, offer a safe local preview/narration while waiting to sync. Label link-only captures as requiring a connection. Keep the original capture until preparation is durably complete. |
| Medium | There is no common connection-restored refresh path. Saved reloads on foregrounding, article progress retries periodically, and lists have their own refresh triggers. An open failed reader does not automatically recover when connectivity returns. | Add a coordinated, debounced recovery trigger for visible content and durable queues, with backoff and cancellation on account changes. Use actual request outcomes as authority; a connectivity hint alone does not prove the server works. |

Relevant implementation locations:

- `ios/Hearful/Views/{ArticleView,LatestView,LibraryView,ShowDetailView}.swift`
- `ios/Hearful/Audio/{PlaybackRestore,ArticlePlayer,PositionReporter,ArticleProgressSync,ArticleProgressJournal}.swift`
- `ios/Hearful/Views/SavedView.swift:SavedLibrary`
- `ios/Hearful/ContentView.swift:VoiceSheet` and foreground handling
- `ios/Hearful/Auth/AuthController.swift:bootstrap` and `refreshUser`
- `ios/Hearful/Intents/{ShortcutPlayback,ShortcutLibrary}.swift`
- `ios/Hearful/API/EpisodeFiling.swift:fileEpisode`

## Rendering and media boundaries

The HTML reader renders a local document; the API is not involved in rendering
each paragraph. Missing remote pictures should therefore not prevent the main
text being displayed. Embedded images already present in the HTML are a
different case from external image URLs and can work offline.

The WebKit coordinator does not currently implement content-process termination
recovery or a navigation-failure fallback. This is a separate possible source
of a blank reader while narration continues. It was not reproduced during this
review. Reloading the retained local document, then falling back to plain text
with a retry action, would make this path more resilient without a connection.

Remote images and podcast audio do not have a dedicated durable download store
in the reviewed iOS implementation. `AudioPlayer` builds an `AVPlayerItem` from
the episode URL. Any buffered audio is not a promise that an episode is available
offline. Reliable podcast downloads are a separate feature requiring download
state, storage limits and removal controls. Article image downloads are a useful
later improvement; videos, external links, new extraction, discovery and AI
requests still need a connection unless their required content is already local.

## What already works and should be preserved

- A stored login opens the app optimistically; an ordinary network failure does
  not sign the user out.
- Text and HTML caches use atomic files in Application Support, and distinct
  explicit article versions do not overwrite each other.
- Modern article bookmark reports survive process recreation and retry; they
  include content identity and revisions to handle other-device changes.
- Safari captures have a durable account/server-scoped local inbox.
- Transport/speed command parsing and installed speech synthesis are local.
- Existing 401 handling and sign-out cache removal must continue to work.
  Any new store must scope reads, writes and in-flight responses to the account
  and server, including responses completing after sign-out or a server switch.

## Android comparison

Android already has several useful patterns to mirror: `FileLibraryCache`
persists account-owned text and HTML, `AccountLibrary.changeSession` restores
that cache before refresh, `AccountLibrary.content` returns already loaded text
for reading, and search seeds filtered local results before requesting the
network. Podcast and article progress both have durable queues.

Playback still refreshes content selection before using its offline fallback;
filing operations still require a network mutation. `AccountLibrary.refresh`
loads Saved metadata but does not itself eagerly download every saved article.
These deserve the same explicit offline-availability and retry requirements.
The older statement in `docs/android-library.md` that article text is not
persisted is out of date relative to the current implementation. No Android
runtime testing was performed for this review.

## Suggested delivery and acceptance checks

1. Unify article content lookup, make local reads immediate, restore last-played
   metadata offline, and recover failed readers. No API contract change is
   inherently needed for these fixes.
2. Add Saved download visibility/retries and unblock local voice after cold
   start; add local publication search.
3. Add durable podcast progress and selected library mutations, then evaluate
   managed article images and podcast downloads as separate features.

Test both immediate no-connection errors and requests that hang while cached
content exists. Cover reader-first and player-first access; unknown-to-known
content versions; exact-version misses; replacement on another device; offline
kill/relaunch; pending capture uploads; loss of connection between saving and
downloading; restoration of connectivity while remaining in the app; and
sign-out/server changes during in-flight requests. Preserve content identity,
reading position, VoiceOver feedback and accessibility controls throughout.

Physical-device acceptance should include airplane mode, weak Wi-Fi without
working internet, installed/uninstalled speech models, and reconnecting after
an offline session. Simulator checks cannot establish those phone behaviours.

## Investigation verification (before implementation)

Source inspection covered the reader, narration, saved-content preparation,
backend content selection, list/search fallbacks, authentication, shortcuts and
progress persistence. Two temporary characterization tests exercised the two
cache-key mismatches above using the real API decoder with a mock transport.
They compiled, together with the existing focused tests, but did not execute:

- Project `ios/Hearful.xcodeproj`, scheme `Hearful`, Debug, iPhone 17 / iOS 27.0:
  build-for-testing succeeded with no compiler warnings found in the build log;
  the runner lost its connection to `testmanagerd` before any tests ran.
- A retry using the prepared test products on iPhone 17 / iOS 26.5, with parallel
  testing disabled, stalled before test execution and was interrupted.
- The sandboxed `make ios-doctor` could not access CoreSimulator services/logs.
  XcodeBuildMCP could enumerate both installed runtimes. This is an environment
  limitation, not an app assertion failure.

The temporary tests were removed from the source tree after compilation. No
application code or existing tests were changed by this investigation. Runtime
reproduction and physical-phone verification remain outstanding.

## Implementation follow-up — 19 September 2026

Implemented in the iOS client:

- Shared, validated article lookup for reading, narration, Saved preparation and
  shortcuts. Versioned content is persisted under its canonical identity, with
  a selected-copy alias for unversioned requests. Legacy cache entries remain
  readable when their identity matches. Readers display local content before
  refreshing and recover when another consumer downloads the text. A terminated
  WebKit content process reloads the retained document.
- Cached Latest, Following, Saved and publication lists appear before network
  requests complete. Publication search filters local items and labels the
  limited offline results. Last-played metadata is persisted with its account
  scope so relaunch and shortcuts can resolve local articles without a request.
  Starting cached narration bounds remote reconciliation to two seconds.
- Saved rows show download availability and failures, with manual retry.
  Preparation runs at most three downloads concurrently, validates content
  identity and confirms disk writes. Original captures remain in the local
  inbox until prepared text is stored successfully.
- Local voice controls are available without a successful consent lookup, using
  on-device recognition only. Remote requests and remote recognition remain
  gated by verified consent. Missing on-device recognition produces an
  explanation rather than silently switching to network recognition.
- Podcast positions now use a durable account-scoped journal, stable request
  IDs and revision checks through the existing podcast progress endpoint.
  Conflicts cannot replay an obsolete clock over a deliberate filing change.
  Legacy article seconds reporting remains best effort; modern articles already
  use their durable text-bookmark journal.
- Read/unread and dismissal actions are persisted before upload and applied
  locally, with pending status, retry and Undo. Undo identifies its original
  action so it cannot undo an unrelated action made on another device.
  Rejected changes remove their optimistic cached flags and request a refresh.
- Connectivity restoration, foregrounding and a periodic retry trigger recover
  failed visible content and pending work. Durable queues and Saved preparation
  back off after failures; manual retry or a restored connection retries sooner.

### Backend contract and rollout

The additive `POST /actions/offline` endpoint accepts `action`, `episode_id`,
`content_id`, `request_id` and, for Undo, `undo_request_id`. It uses the existing
command receipts, binds retries to the complete intent, validates ownership and
selected content, and permits filing owned standalone saved articles. An Undo
target must match the stored original action. Existing `/actions` behaviour and
the frozen released-client sources are unchanged; Android continues to use its
existing endpoints.

Deploy this backend update through the normal staging and promotion process
before releasing the updated iOS app. On an older backend, queued filing fails
safely and remains on the device with a service-update message. No deployment,
release, signing or version change was performed for this work.

### Remaining boundaries

Managed podcast downloads, downloading remote article images, local previews of
unprocessed browser captures, and queueing add/remove Saved operations remain
separate features. Podcast playback still needs reachable media or audio already
buffered by the player. Local voice needs an installed supported speech model.
Physical-device acceptance should still cover airplane mode, unreliable Wi-Fi,
background termination, speech-model availability and reconnection.

### Implementation verification

- `make backend-check`: lint, formatting and type checking passed; 1,118 backend
  tests and 98 repository-script tests passed.
- `make backend-compatibility`: three contract tests and all 21 frozen v1.4.1
  client exchanges passed.
- Full final iOS 26.5 suite: 617 tests passed, zero failed, one existing skip
  (`replayRecordings`), with no compiler warnings. Regression tests cover shared
  text lookup, stalled requests with cached content, disk-write failures,
  account isolation, local voice, durable progress, filing retry, targeted Undo
  and rollback of rejected optimistic state.
- iOS 27 compilation completed without compiler warnings, but its
  simulator could not prepare the device (`Invalid connectionUUID specified`),
  so no tests executed on that runtime. This is an environment failure, not a
  failing app assertion.
- No physical-phone or Android runtime verification was performed.
