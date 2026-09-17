# Android parity checklist

Baseline: source review against the current iOS app, 11 September 2026.
Updated: 17 September 2026.
Numbers match the review. A checked item covers the implementation described
here; emulator results do not establish physical-device audio or TalkBack quality.

- [x] **1. Accounts and live library.** Apple and Google sign-in, explicit linking,
  encrypted sessions, sign-out/deletion, and account-backed Following, Latest, and
  Saved are implemented. Staging acceptance verified both linked providers and the
  real library. Samples and local inboxes remain isolated. Release signing and
  production promotion remain release tasks; see [sign-in setup](sign-in.md) and
  [library verification](android-library.md).
- [x] **2. Real podcast playback.** Streams publisher HTTPS audio URLs, resumes
  saved media positions, and reports podcast progress. Fixture playback and
  account-change cleanup passed on the emulator; phone audio acceptance remains.
- [x] **3. Discovery and subscribing.** Podcast directory and library search,
  website/feed discovery, candidate selection, readable/playable previews, and
  explicit subscriptions. Web publication search is an explicit action gated by
  current account AI consent. Partial search failures preserve successful results;
  query/session changes discard stale replies.
- [x] **4. Source management.** Combine subscribed publications, separate secondary
  sources, and unsubscribe from a feed or discovery preview. Following and feed
  contents refresh after changes; Saved, loaded text, and active playback remain
  available. Primary and failing sources are identified, private feed URLs are
  hidden, and forwarded newsletters explain how to stop forwarding.
- [x] **5. Saved article preparation.** Durable account-scoped pending links,
  explicit import of links saved before sign-in, failed-capture retry, and confirmed
  text replacement. Changed text clears old playback and bookmarks; failed or
  unchanged replacements preserve the current copy. Queue syncing runs in the
  foreground when Saved opens, on refresh, or on explicit retry.
- [x] **6. Incoming sharing.** Receive one shared web link and optional HTML with
  a confirmation preview. Capture page opens an HTTPS page inside Magpie and
  extracts its visible article using the same pinned Readability script as iOS.
  Confirmed captures persist in the account queue, preserve offline content, and
  update existing copies through the established replacement contract. Android
  browsers do not provide Safari's page preprocessing hook: website sign-in may
  be needed inside Magpie's browser. Phone/publisher acceptance remains.
- [x] **7. Ask Magpie conversations.** On-device recognition and spoken replies,
  typed input, local and account commands, explicit AI consent, follow-up timing,
  interruption recovery, and service-owned playback coordination. Emulator coverage
  includes actual offline speech output; phone microphone/TalkBack acceptance remains.
- [x] **8. Assistant and shortcuts.** Android equivalents of the iOS hands-free actions.
  Launcher/pinned actions, Quick Settings, account-scoped Continue listening,
  trusted Ask microphone launches, media-client library browsing/search, structured
  lookup/status, playback controls, structured filing/Undo, destination actions, and
  free-form requests, following a publication URL, and the newsletter-address action
  are implemented. All 56 assistant integration checks pass on the emulator;
  real-assistant and phone acceptance remain separate.
- [x] **9. Newsletters.** Address presentation/sharing/read-aloud, sender approval/blocking,
  explicit signup and the newsletter-address assistant action are implemented.
  Protocol, account isolation, sharing, UI and speech-coordination checks pass;
  large-text/dark-mode and signup screens were visually inspected.
- [x] **10. AI consent controls.** The discovery flow discloses AI data sharing
  before granting permission. Settings reads, reviews, grants, and withdraws the
  same backend account permission used by iOS. Declining never runs an AI search.
  Implemented alongside item 3 because web discovery depends on it.
- [x] **11. Progress sync and offline content.** Account-scoped caches and backend
  progress reporting. Do not send rendered Android article seconds through the
  existing position API; its timeline differs from the iOS article timeline.
  Persistent account content caches and durable guarded podcast progress are
  implemented. Free-form and structured filing/Undo recovery survive restart.
  Shared article bookmarks are connected to Android and iOS playback with durable
  retries and text-based resume. Both clients verify the same Unicode coordinate
  independently of voice timing. Automated contract, restart, completion and
  conflict checks pass; physical-device acceptance remains separate.
- [x] **12. Per-item filing.** Played/unplayed and read/unread across Latest,
  publication lists, search, Saved and the reader; individual Latest dismissal
  and restoration. Visible menus, accessibility actions, durable typed retries
  and playback coordination are implemented. Unread resets a bookmark; Undo
  preserves the prior bookmark. Samples remain local.
- [x] **13. Listening status and metadata.** Continue listening, live progress,
  completed/current-item labels, publication dates, and publisher artwork.
  Latest groups unfinished listening items without duplication. Rows follow the
  active player, use actual podcast duration, and keep article progress in text
  coordinates. Dates and artwork survive account caches and request recovery;
  artwork also reaches publication headers, both players and system media controls.
- [x] **14. Article startup and length.** Playback prepares the resume passage
  first, then generates audio as the player needs it, without the 30,000-character
  guard. A bounded private cache, cancellable offline voice, one shared media item
  and text-coordinate bookmarks preserve seeking, completion and account isolation.
- [x] **15. End-of-item behavior.** Completing a podcast or narrated article marks
  it finished (on the backend when signed in), resets its replay bookmark, clears the player and timer,
  and plays a completion tone. Saved updates without reopening. Pausing or
  manually closing an unfinished item preserves its bookmark and does not mark it
  finished. Live Latest respects server filtering. Per-item filing and status
  presentation are covered by items 12–13.
- [x] **16. Diagnostics.** Account-connected voice attempts and crash/freeze
  summaries, private bounded retries, original-session attribution and a Settings
  opt-out. No transcripts, audio, titles or raw stacks enter diagnostic payloads.
  Unit and emulator checks cover privacy, restart, account changes and a controlled
  foreground freeze; physical-device crash and performance acceptance remain.

## First implementation

Item 15 was implemented independently while the sign-in choice for item 1 was
pending. `PlaybackService` owns completion so it also works in the background.
The existing timer sound is shared through `PlaybackFeedback`; finishing clears
the sleep timer to avoid a later duplicate signal. The UI refreshes the persisted
finished set when it observes/polls service state.

`PlaybackCompletionTest` covers real podcast completion in the background,
article completion and the live Saved update, player dismissal across activity
recreation, replay from the beginning, and manual pause/close preserving progress.
Its article test is explicitly skipped if an offline voice is missing; it must
not claim a successful narration path in that case.

Verification on 11 September 2026: `make android-check` passed (23 JVM tests,
both debug APKs built, no lint issues or compiler warnings reported).
`ANDROID_SERIAL=emulator-5554 make android-test` passed all 38 tests on the
Android 16/API 36 emulator, with no failures or skips. The three new completion
tests also passed in isolation, including actual offline article narration.

## Discovery implementation

On 15 September 2026, items 1–2 were reconciled with the completed account-library
work, and the next unfinished item (3) was implemented. Item 10 was completed as
its consent dependency. No backend or Swift contract changes were needed.

`SourceDiscoveryTest` covers debouncing and URL routing, multiple-feed choice,
explicit successful subscriptions, failure/retry, partial results, late replies,
account changes, and the AI consent gate. Emulator journeys additionally exercise
activity recreation, reading an article before subscribing, large-text/dark-theme
navigation, and consent withdrawal from Settings. Test requests use fixtures and
never modify the owner's subscriptions or AI permission.

Verification: `make android-check` passed all 61 JVM tests, compiled both debug
APKs, and passed lint without compiler warnings. The five focused discovery
instrumentation tests passed, followed by all 58 tests in the full Android 16/API
36 emulator suite, with no failures or skips. The installed build was also checked
against staging: Planet Money directory results and a populated podcast preview
loaded, and the Astral Codex Ten website resolved to a populated article-feed
preview. The live preview screenshot was visually inspected. No live subscription
or AI-permission writes were made. Phone, TalkBack, and Bluetooth acceptance
remain outstanding.

## Source management implementation

On 15 September 2026, item 4 was implemented using the existing backend endpoints.
Source changes use stable IDs, prevent duplicate submissions, discard replies
after account changes, and invalidate results from an earlier feed grouping.
A confirmed change followed by a failed refresh is shown separately from a failed
write, so retrying a refresh does not repeat the mutation.

Repository and screen tests cover combining, separating, unsubscribe failure and
retry, stale replies, activity recreation, preservation of Saved and active
podcast playback, and scrollable controls at 200% text size in dark mode. All
subscription writes in tests use isolated fixtures.

Verification: `make android-check` passed all 69 JVM tests, built both debug APKs,
and passed lint without compiler warnings. The full emulator run completed 51
tests successfully before host overload caused a sleep-timer failure and stalled
the next test. After recovery, all five source-management tests, five discovery
tests, the interrupted capture test, and the sleep-timer retry passed. Together
these runs cover all 63 Android 16/API 36 instrumentation tests. Phone, TalkBack,
and Bluetooth acceptance remain outstanding.

The large-text/dark-theme screenshot check was repeated after dismissing a stale
Android system ANR dialog, and the unobstructed result was visually inspected.
The updated preview was installed and staging sign-in restored. Ahead of AI’s
source-management screen loaded its primary source and available subscriptions;
the live screenshot was also inspected. No live subscription changes were made.

## Saved article preparation implementation

On 15 September 2026, item 5 was implemented with the existing `/saved`,
`/saved/{id}/retry`, and `/saved/replace` contracts. No backend or Swift changes
were required. Pending entries preserve their original saved timestamp and remain
on disk until the server confirms the save. Account and server boundaries apply
to queued links, including after an offline restart of an identified session.
Links saved before sign-in require review and confirmation before importing.

Tests cover disk persistence and deduplication, partial connection failures,
account changes during requests, stale article replies, explicit retry, replacement
confirmation/cancellation, unchanged versus changed playback, and large-text/dark
mode. All article captures and replacements in tests use isolated fixtures.

Verification: `make android-check` passed all 78 JVM tests, built both debug APKs,
and passed lint without compiler warnings. All eight new Saved instrumentation
journeys passed, including actual offline narration and confirmed device-link
import. The full Android 16/API 36 run passed 70 of 71 tests and exposed an initial
connection error being cleared by an empty search. That regression was fixed and
covered by a unit assertion; the complete live-library class then passed. The
playback-completion class also passed after adding a guard against old completion
updates marking replacement text as read. Across the full run and focused reruns,
all 71 emulator tests passed, with no skips. The large-text/dark-mode replacement
dialog screenshot was visually inspected. The final preview was installed,
staging sign-in was restored with Apple and Google connected, and the live Saved
screen and replacement control were visually checked without changing articles.
Phone and TalkBack acceptance remain.

## Incoming sharing implementation

On 16 September 2026, item 6 was implemented using the existing `/saved/replace`
contract. Shared text/HTML needs one valid web URL and explicit confirmation;
unsupported or ambiguous input gets a clear explanation. The standalone share
screen previews text without executing sender HTML. A separate activity task
keeps its unconfirmed preview available while the user opens Magpie to sign in.
A changed account requires fresh review. Opening Magpie after a save starts
foreground preparation in Saved; closing the share keeps accepted content on disk.

Capture page is available from the share preview and saved articles. It opens
HTTPS pages inside Magpie, allowing website sign-in before the user requests
extraction. The build bundles the existing iOS Readability asset and license,
including hidden-content removal, canonical identity checks, and link fallback
for uncertain articles. Navigation invalidates old extraction callbacks. The
capture WebView has no native bridge, app tokens, file/content access, insecure
mixed content, third-party cookies, downloads, or website permission grants.
Website cookies are separate from the sending browser; Android does not capture
the sending browser's existing tab DOM. Unconfirmed browser content is not stored
in an activity Bundle; process death returns to the original share for review.

Confirmed title/HTML/format and replacement intent survive offline storage and
restart. Each confirmed capture keeps its own ID and upload order, preserving
earlier offline content if a later capture fails and preventing an older in-flight
response from removing newer content. Legacy URL-only entries remain compatible. Existing changed
content handling stops old narration and rejects its old bookmark. No backend,
Swift contract, release configuration, or production service was changed.

Verification: `make android-check` passed all 83 JVM tests, built both debug
APKs, and passed lint without compiler warnings. The full Android 16/API 36 run
passed all 78 then-existing emulator tests, with no skips. After the final queue,
share-task, and app-resume adjustments, the complete IncomingSharing (9),
SavedPreparation (8), and LiveLibrary (4) classes passed individually. Across
these runs all 80 current emulator tests are covered. The combined class filter
selected only its first class, so individual runs were used to verify the rest.
Browser capture and 200% text/dark share screenshots were visually inspected.
The tests use isolated accounts and page fixtures; no live articles were changed.
The final preview was installed, and Android resolved both plain-text and HTML
share intents to Magpie. Phone, TalkBack, and publisher sign-in acceptance remain
outstanding.

## Ask Magpie implementation

On 16 September 2026, the Android voice core gained whole-utterance local
playback/sleep commands, explicit conversation-ending and undo phrases, bounded
follow-up preferences, and account/server-scoped in-memory conversation context.
Requests carry the most recent eight prior turns and eight recent actions;
120 seconds of silence expires the subject. Interrupted requests retain their
original request ID and payload for safe recovery until their client-side effects
have succeeded. Late receipts cannot clear a newer request or cross accounts.
Invalid or ambiguous timer durations are left unresolved rather than silently
using a different duration.

The first core milestone passed 95 JVM tests, both debug APKs, and lint.
At that stage the Ask UI was still a placeholder; the completed integration is
described below.

The second milestone implements the existing `/command/stream` NDJSON and
`DELETE /command/{request_id}` contracts. Incremental text is presentation only;
a final receipt is required before effects can be applied. Truncated, malformed,
oversized, contradictory, or duplicate receipts are rejected. Streams have a
five-minute overall deadline and cancellation closes their connection off the UI
thread. Authorization never follows redirects. Account-bound operations reject
late replies after a session change while cancelling with the original account
and request ID. Confirmed episodes can enter the player cache without inventing
Saved or Latest membership.

Verification: `make android-check` passed 104 JVM tests, both debug APKs, and lint
without compiler warnings. All six `VoiceWireTest` cases passed on Android 16/API
36, including streaming Unicode, compound effects, 401 handling, redirect rejection,
and disconnecting a blocked reader. These use isolated connections and never send
live transcripts or account mutations.

The third milestone adds an on-device-only recognition adapter, microphone
permission checks, language capability detection and explicit model downloads,
plus spoken replies using the selected installed offline voice. Partial
recognition stays provisional until a final result arrives. First-word, silence,
startup, and final-result waits are bounded; cancellation destroys the native
recognizer. Replies wait for actual audio completion, split long text without
breaking Unicode, and stop on cancellation or audio interruption. Engine callbacks
from an earlier attempt cannot complete a later one. No recording is retained.

Verification: `make android-check` passed 118 JVM tests, both debug APKs, and lint
without compiler warnings. All five `VoiceAudioTest` cases passed on Android
16/API 36 with no skips, including an actual offline spoken reply, missing-voice
and permission handling, recognition callback mapping, and the native capability
query. Recognition timing and cancellation use controlled engine callbacks;
this does not establish real microphone transcription quality.


The fourth milestone connects Ask Magpie throughout the app and article reader.
The conversation screen accepts microphone or typed input, shows provisional
captions and completed turns, requests microphone permission explicitly, and
provides recognition capability checks and model downloads. AI permission is
required before sending library requests; local playback and timer controls
work without it. Follow-up capture begins only after spoken audio finishes and
honours Keep listening and the selected 10/15/20/30-second wait. Typed requests
and TalkBack use manual turns. Closing, backgrounding, and recreation stop the
microphone; returning requires another explicit Listen tap.

The playback service owns each conversation's pause/resume decision. Explicit
media controls, account changes, unplugging audio, and sleep expiry invalidate
that decision. Uncertain remote outcomes leave playback paused and retain the
original request for recovery. Already-confirmed server filing is reconciled
before speaking, so cancelling a confirmation cannot silently reverse it.
Compound responses speak once before the final playback choice. Undo restores
podcast media positions and same-version local article text bookmarks without
sending Android article seconds to the backend. Filing another library item
preserves unrelated playback.

Verification of the integrated flow: `make android-check` passed 130 JVM tests,
built both debug APKs, and passed lint without compiler warnings. The full
Android 16/API 36 suite passed all 103 then-existing tests. The final conversation
class passed 15 of 16 cases; its article Undo test initially captured an old
bookmark before the service finished seeking. After waiting for the actual
service position, that case passed in isolation. Across the full run and focused
reruns all 107 current emulator cases are covered, with no skips. Coverage includes
actual offline spoken replies and article narration, consent decline/grant,
original-request recovery, account changes, explicit media controls, sleep expiry,
compound actions, current and non-current filing/Undo, follow-up timing, and
activity recreation. The 200% text/dark conversation screenshot was visually
inspected, including system-bar contrast. Tests use isolated accounts and controlled
recognition callbacks; no live transcripts or library mutations were sent.
Physical microphone, TalkBack, Bluetooth, and phone audio acceptance remain.

The next unchecked item is **8. Assistant and shortcuts**.

## Assistant and shortcuts implementation in progress

The first item 8 milestone adds four launcher actions, a settings page for
pinnable library/show actions, and Ask/Continue Quick Settings tiles. Continue
uses a separate account-scoped last-item choice, preserves a loaded player's
newer clock, and can resolve an older item outside Latest/Saved through the
existing episode endpoint. No backend or Swift contract changed. Targeted pins
validate the owner; external intents cannot submit AI transcripts or start the
microphone. Late requests are discarded after account or playback changes.
Intent delivery is consumed once, including across activity recreation.

Verification on 16 September 2026: `make android-check` passed 130 JVM tests,
built both debug APKs, and passed lint without compiler warnings. All 14 focused
shortcut journeys passed, including real launcher pin confirmation, native Quick
Settings activation, cold/warm intent delivery, activity recreation, loaded and
older-item continuation, owner validation, cancellation, external pause, and
account changes during lookup. The final full Android 16/API 36 run passed all
121 emulator tests with no failures or skips. The 200% text/dark shortcut screen
was visually inspected after fixing its wrapping heading and system-bar contrast.
Tests use isolated accounts and restore their Quick Settings configuration; they
do not submit live requests or change the owner's library. Physical launcher,
TalkBack, Bluetooth, microphone, and assistant acceptance remain separate.

The second milestone connects trusted Ask launcher/pin/tile launches to the
microphone. A private installation proof distinguishes these launches from forged
exported intents; only the foreground, unlocked conversation can request Android
permission and start listening. TalkBack retains manual Listen. The launch is
consumed once and does not survive backgrounding, recreation, closing, typing a
new request, or account changes. Delayed permission replies cannot activate a
different conversation. Repeated disposal cannot reverse a service decision to
keep playback paused after an explicit interruption.

Regression checking exposed an overlapping-refresh race: an old library response
could replace a confirmed voice filing with its earlier unplayed snapshot.
Confirmed receipts now join the repository's existing serialized updates. A
controlled JVM regression reproduced the failure before the fix and passes after it.

Verification of the second milestone: `make android-check` passed all 134 JVM
tests, built both debug APKs, and passed lint without compiler warnings. The final
Android 16/API 36 full run passed all 124 emulator cases with no failures or skips,
including all 17 shortcut cases and all 16 conversation cases. Coverage includes
trusted launcher and native tile activation, forged intents, launch consumption,
background/recreation cancellation, and controlled permission denial/late-grant
callbacks. The initial conversation run exposed the filing failure above; the
final full run passed after the ordering fix. The updated 200% text/dark shortcut
screen was visually inspected. Microphone input uses controlled callbacks in
these tests; physical speech quality, TalkBack, and Bluetooth acceptance remain.

The third milestone exposes Latest, Saved, followed shows, and account search to
trusted Android media clients. Media3 and legacy platform browsers use the same
service player and account repository. Browsing does not load article text or
expose playback URIs, and it preserves the app's displayed search. Folder IDs are
account-scoped; subscriptions to old folders are invalidated after an account
change. Unpaged legacy folder requests and overflow-safe pagination are supported.

Prepare resolves the item and its bookmark without starting playback. Play then
uses the prepared podcast or on-device article audio. Search supports a named
episode, a followed show's latest unfinished item, or Latest for an empty playback
query. A loaded item's newer clock is retained. Pending lookups/rendering are
bounded and cancelled on account changes, independent media controls, sleep expiry,
audio disconnection, or caller disconnection. Caller-provided URIs and queues are
rejected. Legacy service binding admits only Media3's anonymous browser placeholder;
the actual caller is checked before library/player access.

Focused verification: all 17 media-library emulator tests passed, including
modern and legacy preparation/playback, unpaged browsing, search isolation,
pagination, account-switch notifications, delayed-result cancellation, offline
article rendering/bookmarks, and rejection of a separate app without media access.
Controlled regressions exposed two additional races: an older single-item read
could overwrite a confirmed filing, and Media3 could drain a queued Play after
preparation was cancelled, restarting the previous item. Single-item lookups now
join the repository's serialized updates, and a short-lived playback guard stops
the cancelled caller's queued Play while preserving the old item/bookmark. A fresh
explicit Play remains available. Both regressions failed before their fixes.

The full Android 16/API 36 run passed all 138 emulator cases with no failures or
skips before these final race fixes. The final `make android-check` passed 135 JVM
tests, both debug APK builds, and lint without compiler warnings. Final focused
runs passed all 17 media-library, 3 playback, and 16 conversation tests. One initial
conversation assertion timed out waiting for a filed item to leave the player;
it passed in isolation and in the complete conversation rerun without further
production changes. The test now retains receipt/error/player-state diagnostics.

The fourth milestone adds structured AppFunctions for listing followed shows,
finding library items, and reading listening status. Discovery follows account
availability, and each invocation independently validates the current account.
Find supports show, unheard, duration, and result-count filters across the first
100 candidates. Unknown durations remain unknown and are excluded by a supplied
duration ceiling. Scoped show IDs cannot cross accounts. Search preserves the
app's displayed results and does not load article text. Status connects to the
existing player without starting it. Android 12–15 keep this service disabled.

Nine platform integration tests passed on the separate Android 16/API 36.1
small-phone emulator, with no failures or skips. They invoke the generated service
through Android's AppFunctionManager, covering schema serialization, default and
filtered results, validation, stale account IDs, signed-out access despite stale
discovery state, sign-out/sign-in discovery updates, account changes during a
lookup, caller cancellation, and read-only player status. The APK contains the
generated metadata and schema. A compatibility attempt on the original API 36
image timed out waiting for registration; its legacy registry does not index the
current generated schema. That run was stopped after the first setup timeout; the next case was interrupted.
Structured actions are unavailable on that image; the test suite explicitly
requires API 36.1 or newer images, while ordinary app/media tests remain on API 36.
The final `make android-check` passed all 135 JVM
tests and both APK builds, with no compiler warnings or lint errors. Lint still
reports eight warnings and one hint in existing credentials, dependencies, assets,
shortcuts, and convenience-API usage. This establishes platform integration, not Gemini
availability or physical assistant acceptance.

The fifth milestone adds structured pause, skip, seek, set/undo speed, set/cancel
sleep timer, explicit item playback, Continue, and Latest/show playback. A private
Media3 command validates account revision and target IDs at the service boundary.
Playback reuses the existing catalogue, renderer, bookmarks, and player, and only
confirms a start once audio is playing in a foreground service. Android's
background-start denial produces a one-use, immutable, account-scoped action to
open Magpie for the selected item. Pending preparation/start is cancelled on caller
disconnection, account changes, or independent media controls. Local controls do
not wait for library refreshes. Speed undo is limited to the originating account,
content kind, resulting speed, and ten-minute lifetime.

Controlled regression tests exposed stale-account targets pausing current audio
before rejection, and Pause waiting behind an unrelated library refresh. Both
paths now validate/operate before asynchronous library work. Cold-service tests
use a server fixture that returns acknowledged progress, and await service
confirmation before disconnecting test controllers. Actual offline article
rendering, seeking, and continuation are exercised without podcast progress writes.

Verification on the small-phone API 36.1 emulator: all 22 AppFunction integration
tests passed. The full 163-test run passed 157 cases and exposed four existing
small-screen scrolling assumptions, an unreliable synthetic WebView navigation,
and one compound voice-playback timeout. Tests now scroll lazy lists to their
targets and serve the capture fixture through normal WebView request interception.
Final focused runs passed all ten account tests, six navigation tests, the capture
extraction test, and all sixteen voice-conversation tests. The voice timeout did
not recur in that complete group; its timeout and state diagnostics are retained.
The initial full run could not exercise Compose UI on this image because its
transitive Espresso version used a removed InputManager method. Pinning Espresso
3.7.0 applies the documented AndroidX fix without changing application behavior.
The final `make android-check` builds both APKs and passes all 135 JVM tests;
there are no compiler warnings or lint errors. The existing eight lint warnings
and one hint remain.

Cold-service playback was tested with no activity visible, in the existing app
process. Full process-death playback and the actual foreground-start-denial
handoff remain separate acceptance checks; the emulator did not trigger that
denial. Physical assistant/Gemini, phone audio, Bluetooth, and TalkBack acceptance
are not established by these tests.

The sixth milestone adds structured played/read, dismissed, and restored actions,
plus library Undo, using the existing authenticated `/actions` contract. Explicit
IDs are validated before interruption; an omitted ID selects the loaded item.
Uncertain current-item retries retain that original target even if playback moves
on. A shared account coordinator rejects concurrent mutations and retains both
request IDs and confirmed receipts until reconciliation completes. Session changes
clear this context and discard late replies. These typed actions do not use AI.
An explicit new-change option allows a fresh attempt after reviewing a stopped or
unconfirmed request; default retries retain their original identity and target.

Playback coordination reuses the voice hold, progress-write drain, filing, and
bookmark restoration paths. Older progress finishes before the server change;
confirmed filing cannot be overwritten by the previous player clock. Uncertain
results leave audio paused. Caller cancellation, account changes, or independent
media controls cancel the original account request. The cancellable HTTP transport
also closes the socket, bounds JSON receipts, and refuses credential redirects.
Library Undo and local speed Undo are separate structured actions with explicit
descriptions; free-form Undo context remains part of the next adapter milestone.

A controlled regression against the previous service reproduced a lost filing
reply followed by switching playback: the old podcast clock cleared the server's
completed state. The service now guards uncertain progress by original request
ID, including after the playback hold is invalidated. Confirming another request
does not release an older uncertainty. Filing/restoration receipts adopt the
confirmed item state, and request confirmation releases the matching guard.
These guards and retry receipts are in-memory; durable process-death recovery
remains part of item 11.

Verification for this milestone: `make android-check` passed all 143 JVM tests,
built both debug APKs, and reported no compiler warnings or lint errors; eight
existing lint warnings and one hint remain. All 36 structured-action tests passed
on API 36.1. The regression for an uncertain filing followed by switching playback
failed against the previous service, then passed with the progress guard.
The shared voice group passed 15 of 16 cases; its confirmation-state timeout
passed on a focused rerun with the same five-second limit. Failure-state
diagnostics are retained. All 17 media-library tests and seven reader tests passed.
The initial full 179-case run passed 177 cases, exposing manual-scroll inertia in
a reader test and service teardown timing in a media test. Their final group
reruns pass after using a stable manual drag and awaiting player dismissal before
releasing test controllers. All ten HTTP voice/action transport cases passed in
the full run. No backend or Swift contract changed.

The seventh milestone adds structured navigation actions for Latest, Following,
Saved, Now Playing, Shortcuts, a listening item's details, and a followed show's
items. The assistant receives an immutable, one-use action for the user to open;
creating it does not open an activity, start playback, or request microphone access.
Generic destinations remain discoverable before sign-in. Item/show actions require
an authenticated account and validate unchanged scoped IDs.

Delayed actions revalidate the account before interrupting a conversation or
loading content. Opening a removed show fails with an explanation. The screen
also checks account/catalog ownership when consuming the resolved route, guarding
a change between model resolution and the next UI frame. Opening an item or show
preserves the existing player. Validated shortcuts cancel earlier article preparation
before waiting for their own lookup, preventing an old request from starting
audio late. All actions reuse the app's existing navigation and
permission boundaries; they do not add external deep links or AI requests.

Verification on 17 September 2026: `make android-check` passed all 143 JVM tests,
built both APKs, and reported no compiler warnings or lint errors. Eight existing
lint warnings and one hint remain. Three assistant-interface checks cover typed
navigation results, invalid targets, signed-out access, and availability changes.
The full 21-case shortcut run passed 18 cases; three new link journeys completed
their assertions but failed activity cleanup. Inspection of AndroidX's lifecycle
matcher identified the changed data URI as well as categories. Restoring the test
launch intent after the actual handoff fixes cleanup; all three focused reruns
passed. The additional earlier-preparation cancellation regression passed too,
providing passing coverage of all 22 shortcut cases. The delayed UI-consumption
regression covers both an account switch and a show removed after resolution.
All six ordinary navigation tests passed, including Saved and activity recreation.
The reinstalled sample preview opened Latest through the navigation intent; its
settled screen was visually inspected with no player active.

Item 8 remains unchecked until free-form requests and subscription actions are
implemented and verified. Future assistant adapters
must preserve the trusted microphone launch boundary and Android permission step.
Newsletter shortcut support also depends on item 9. Platform-specific release
and physical-assistant acceptance remain separate from emulator verification.

## Free-form assistant requests

The next adapter milestone exposes `runMagpieRequest` through the generated
AppFunctions service. It shares account-scoped conversation history, pending
request IDs, confirmed receipts, and an execution lease with Ask Magpie. Local
playback controls and speed Undo stay on device; library Undo uses the existing
typed action API. Free-form library requests use existing AI consent and command
contracts. Follow-up questions return `expectsReply` so the assistant can pass the
user's answer with the same conversation history.

Consent and recovery actions retain the original text privately and open Ask
Magpie without microphone capture. Intents carry an opaque, account-scoped,
one-use capability with a ten-minute lifetime; a new library request invalidates older
continuations. A twenty-second deadline preserves the original server request for
recovery. Confirmed receipts survive interrupted local reconciliation, avoiding a
second network mutation. Caller cancellation, account changes, and independent
controls cancel the original operation. Actual foreground service playback is
confirmed before returning success; Android background-start restrictions use the
existing item handoff. Shared speed Undo preserves later manual changes.

Conversation state, receipts, and handoffs remain in memory. Process-death
recovery belongs to item 11. Item 8 remains open for following a publication URL
and the newsletter dependency in item 9.

Verification on 17 September 2026: `make android-check` passed 150 JVM tests and
built both APKs with no compiler warnings or lint errors; eight existing lint
warnings and one hint remain. The full 47-case assistant run passed 46 cases and
exposed a cancelled library refresh leaving `loading` set. The fix preserves the
existing data, releases loading only for the same account, and has two JVM
regressions. Six focused emulator checks then passed: receipt recovery without a
second network mutation, speed Undo shared across interfaces (including later
manual changes), deadline recovery with the original request ID, account-change
and independent-control cancellation, actual consent handoff, and local playback
plus library Undo without AI. Together these runs cover all 50 assistant cases.
The in-app voice regression run passed eight of sixteen cases; the remaining
cases hit request/speech/capture deadlines or Compose idling limits. An isolated
filing rerun also timed out before dispatching its API request. A controlled
comparison using published commit `feaa35f` and the same test diagnostics failed
with Compose idling too. The Mac was under heavy load and the emulator logged
large frame delays. These results do not establish a new regression, but also do
not by themselves clear the changed voice flow. After a full emulator-process
cold start during newsletter verification, all sixteen voice regressions passed
with their original deadlines (see below). The explicit assistant-Pause recheck passed. The consent handoff
screenshot was inspected: the permission dialog is legible and its actions remain
accessible on the small emulator. That screenshot run subsequently timed out
waiting for the request after consent, so it does not replace the earlier passing
functional consent check.

## Following publication URLs through the assistant

`followPublicationUrl` uses existing authenticated feed discovery and subscription
APIs without AI. Multiple candidates return choices without writing; a chosen ID
must still match fresh discovery for the same website, account and session. A
single feed can be followed directly. The result uses the canonical feed returned
by the server and updates Following and Latest. Existing subscriptions are
recognised, including conflict recovery after another device subscribes or a
successful reply is lost. Cancellation or account changes during discovery cannot
start a subscription for a later account.

Verification on 17 September 2026: `make android-check` passed all 155 JVM tests,
built both debug APKs, and completed lint without errors or compiler warnings;
the eight existing warnings and one hint remain. Five new repository regressions
cover choices, canonical results, existing subscriptions, lost replies, stale
choices, cancellation and account changes. The generated AppFunctions integration
test passed on API 36.1, checking choice serialization, no premature subscription,
invalid-choice rejection, the account-scoped result, repeat requests and no AI
requests. The newsletter action was subsequently completed with item 9 below.
The earlier voice timing failures were cleared by a full sixteen-case rerun
after a cold start, as recorded below.

## Newsletters

Android now uses the existing newsletter API for the account address, pending
senders, approval/blocking and explicit website signup. Settings offers accessible
word-by-word and spelled addresses, copying with visible/haptic feedback, sharing,
and offline speech coordinated with the playback service. Speech has no microphone
path, shares conversation ownership, and respects independent controls and account
changes. Pending senders appear in Following and Latest; blocking requires a
confirmation explaining deletion and future filtering. Discovery offers email
signup after failure and preserves the backend's submitted/manual outcome.

Addresses, sender rows, mutations and signup replies are scoped to the account
session. Late pending-list replies cannot restore an approved or blocked row;
failed writes remain available for retry. `getNewsletterAddress` uses the same
account endpoint without AI or a signup side effect. No backend or Swift contracts
changed.

`make android-check` passed 168 JVM tests and built both debug APKs without compiler
warnings or lint errors; eight existing lint warnings and one hint remain. Tests
cover address pronunciation, stale account replies,
serialized sender changes, lost refresh races, explicit signup, manual/submitted
results and speech ownership/cancellation. The first emulator protocol attempt
ran zero tests because Android’s system process crashed before instrumentation
started; Gradle nevertheless returned success. This is an environment failure,
not passing coverage. A full cold start then restored normal execution: all three
newsletter protocol tests, all five UI journeys (including the Android sharing
chooser without selecting a recipient), all 52 assistant integration tests and all
sixteen voice regressions passed with no skips. This includes the previously
timing-sensitive consent handoff and voice cases using their original deadlines.
The newsletter assistant test also verifies that it works while library refresh
is blocked and AI permission is absent. Final large-text/dark-mode address and
sender screens and the manual-signup result were visually inspected. Items 8 and
9 are complete within this implementation and emulator scope; physical speech,
TalkBack and real-assistant acceptance remain release checks.

## Offline library storage

Item 11 now stores Following, Latest, Saved, opened feed listings and fetched
article text/HTML in atomic account-specific files outside the disposable cache.
Snapshots contain library data, not credentials or conversation state. Known
sessions restore only their remembered server/account; new identities must first
resolve through the server. Successful live replies replace the cached lists.
Offline feed browsing and local search retain matching known content with a
connection message; search does not claim to cover unseen account items.

Confirmed filing, removal, content replacement and source changes update the
snapshot. Immutable Saved content selections survive restart without reusing
replaced text. Sign-out clears the account snapshot after any older disk write;
late cache reads cannot restore its UI. Initial restoration is serialized with
refreshes and mutations. Cache errors cannot turn accepted server writes into
reported failures, and corrupt or incompatible files are discarded.

Verification on 17 September 2026: the Android gate passed 175 JVM tests, built
both APKs, and reported no compiler warnings or lint errors; eight existing lint
warnings and one hint remain. Seven new repository cases cover recreation while
offline, account/server separation, sign-out/read/write races, concurrent initial
refresh, confirmed mutations/content replacement and disk-write failures. Two
Android storage tests round-trip every field through fresh store instances and
reject malformed, future-version and foreign-account files. All five live-library
emulator journeys pass, including new repository/storage/identity-store instances
opening a cached article while fixture network calls fail. A focused rerun also checked the actual rendered page text and its visual-ready
callback; the finished offline reader screenshot was visually inspected.

This completes the content-cache portion of item 11. Durable progress retry,
cross-device article bookmarks, and process-death request/receipt recovery remain
open. Podcast audio downloads and cached article images are outside parity scope.

## Guarded progress protocol

The server and Android HTTP adapter now support retry-safe podcast progress, with
an opaque comparison token and an immutable request ID. Stale clocks cannot
replace newer filing/progress, and a lost reply can be recovered without repeating
the write. Current Swift models decode the optional token while released clients
retain their existing endpoint. Account linking/deletion clean up the new receipt
storage. See [the protocol and verification](progress-sync.md).

The backend gate passes 1,002 tests plus 96 repository-script tests; frozen Swift
compatibility passes, and all 16 current iOS auth/position tests pass. Android's
175-test build gate and two protocol checks pass. The iOS build emitted 15 cached
precompiled-module warnings, separate from its passing test result.

Android playback now journals local positions before upload, preserves the exact
request after a lost reply, and coalesces later samples separately. Completion uses
the same guarded write. Preparation does not upload zero; service teardown retains
its final application-owned disk write. Startup restores the account's clock,
and retries run while the app process is alive. A newer server revision prevents
an old playback session from reporting over filing or progress from another device.
Voice filing guards persist before the server mutation and survive reopening
storage; matching confirmation is required to release them. Sign-out clears the
journal. A corrupt journal fails closed while leaving cached library content usable.

Cross-device text bookmarks and process-death conversation/request recovery remain
open, including recovery of the original request needed to resolve an uncertain
filing guard after process death.


Durable-queue verification on 17 September 2026: the final Android gate passes
189 JVM tests, builds both APKs, and has no compiler warnings or lint errors;
eight existing lint warnings and one hint remain. Ten queue tests and four
repository tests cover exact retries, coalescing, completion, lost replies,
newer canonical state, concurrent local samples, missing caches, account changes,
recreation, and durable filing guards. Two Android storage tests verify fresh
journal instances, isolation and corruption handling. Three service tests exercise
offline pause/retry, natural completion and voice progress drains.

The full emulator suite ran 220 tests: 219 passed and one reader gesture assertion
failed. It reproduced with Compose's batched synthetic drag; the same bounded drag
paced through Android's input system passed with the original assertions intact.
The complete seven-test reader suite then passed, and its reading-marker
screenshots were visually checked. This was a test-input correction, with no
reader implementation change. The final three service checks also pass; their
completion assertion waits for both the disk write and asynchronous library
update. Across the full run and focused reruns, all 220 emulator cases are covered
with no skipped cases. Phone, TalkBack and Bluetooth acceptance remain
separate from these emulator checks.

## Durable free-form request recovery

Ask Magpie and the free-form assistant adapter now save the original request before
sending it and save a confirmed receipt before reconciling local effects. The
account/server-scoped journal is private, excluded from backup, and uses atomic
file replacement away from the UI thread. It retains every unfinished request,
including older ones after a newer request starts. Sign-out serializes cleanup
after older writes; account changes reject late reads and receipts.

The conversation screen restores a scrollable list of unfinished requests without
opening the microphone or sending a command. Explicit checking keeps the original
ID, body, target and context. Stored receipts reconcile current server state and
report the historical result without replaying old playback/speed changes or old
filing state. A confirmed dismissal cancels unfinished server work, refreshes the
library, releases the matching progress guard and removes the local record without
undoing prior changes. It works after AI consent is withdrawn. Failed reads,
writes, cancellation or network requests preserve recovery rather than silently
creating a replacement request. Storage is bounded; reaching the limit requires
resolving or dismissing an older request, never discarding it automatically.

The full Android gate passes 198 JVM tests and builds both APKs with no compiler
warnings or lint errors; eight existing lint warnings and one hint remain. Nine
new JVM cases cover original request/receipt retention, older selection, account
and sign-out races, disk failures, restart, and cancellation. Four emulator UI
cases pass, including newer filing preservation, exact request retries, dismissal
confirmation, sign-out cleanup and large-text/dark-mode controls. The recovery
screen was visually inspected. The complete emulator suite passed all 227 tests
with no failures or skips, including 53 assistant cases and both journal-storage
cases.

Item 11 remains open for cross-device article bookmarks; structured filing/Undo
recovery is described below. One-use assistant navigation handoffs remain intentionally
process-local; unfinished requests are accessible from Ask Magpie after a restart.

## Durable structured filing and Undo recovery

Structured assistant filing/Undo now uses the same account-scoped journal and
recovery list as free-form requests. Original action routes, request IDs and
item targets are saved before pausing/draining playback or contacting the server;
receipts are saved before reconciliation. A current-item retry loads its original
target before consulting the player. Explicitly starting a new change retains
older unfinished work in Ask Magpie.

Recovery and confirmed dismissal use the original typed route without AI consent.
Ask Magpie's explicit library Undo also uses that route. Both assistant and Ask
recovery reconcile fresh server state instead of replaying a historical filing
receipt or undoing a subsequent action. All routes share a single execution lease,
so a typed action cannot interrupt another library request. Sign-out clears the
journal; failed storage and invalid receipts preserve the original request. The
journal reads the earlier free-form format and writes schema 2 so an older app
cannot mistake a structured request label for an AI command.

The full emulator run covered 232 cases: 229 passed, and three existing Undo
cases failed because their mock server only supported the former AI route. The
fixture now supports typed Undo and additionally asserts that route is used;
the original podcast/article bookmark assertions remain unchanged. All 16
conversation cases then passed. After the final recovery pause fix, all 56
assistant cases passed, including the case where checking a historical receipt
must leave a now-filed current item paused. Three journal-storage cases verify
format migration and typed receipt validation. All six recovery UI cases also
pass on the final code, and the 200% text/dark-mode screenshot was visually
inspected. Across the full run and focused reruns, all 233 emulator cases are
covered with no skips. Physical phone, TalkBack and Bluetooth checks remain
separate.

The final Android gate passes all 202 JVM tests and builds both APKs without
compiler warnings or lint errors. Eight existing lint warnings and one hint
remain. The backend gate also passes 1,002 backend and 96 repository-script
tests after the local-request privacy disclosure update.

## Shared article bookmark contract

The backend now accepts guarded UTF-16 bookmarks tied to an exact article-text
hash and selected saved version, with immutable retry receipts. Text responses
provide the capability/revision and matching bookmark. Filing, text replacement,
older-client writes, grouped copies, Undo and account linking preserve newer
intent. Swift and Android models/adapters support the additive contract and old
payloads. Both native player integrations are described below.
See [the protocol](progress-sync.md#guarded-article-bookmarks).

The backend gate passes 1,014 tests plus 96 repository-script tests. Eleven new
protocol tests and a reversible-migration test cover Unicode offsets, retries,
conflicts, selected versions, filing/Undo, privacy, expiry, rollback and deletion;
account-linking coverage also includes bookmarks and receipts. All 21 frozen
released-client checks pass on macOS. The iOS auth/position contract suite passes
19 tests, with 13 missing cached-module build warnings reported separately.
Android passes all 202 JVM tests and builds both APKs with no compiler warnings
or lint errors; eight existing lint warnings and one hint remain. Two Android
wire tests and three journal-storage cases pass, including exact typed retries,
invalid acknowledgements, old payloads and article bookmarks in saved receipts.

## Shared limitations

Podcast downloads and offline article images are not counted as Android parity
gaps because the reviewed iOS implementation does not provide them either.
Physical TalkBack, Bluetooth, narration quality, and completion-tone audibility
still need intentional phone acceptance testing.

## Android shared article playback

Android playback now consumes the shared article protocol. Explicit Play refreshes
cached text selections and bookmarks, with matching offline content as fallback.
The service persists text-version/content-ID/UTF-16 samples outside its lifecycle,
retries immutable requests, and handles natural completion through one guarded
report. Later samples wait behind an acknowledged request; newer filing or text
replacement blocks the old playback. Article journals participate in the same
filing holds, drains, request confirmation, periodic retry and sign-out cleanup as
podcasts. Cached summaries retain optional bookmark/capability fields.

Verification on 17 September 2026 covers 219 JVM tests, including 12 article queue
tests and five repository cases. Four emulator service tests pass: offline
pause/recreation/retry, a newer server bookmark despite already-cached text,
natural completion without a legacy write, and durable filing guards. Two article
journal tests and the cache round-trip checks also pass.

The full emulator run covered 240 cases: 236 passed and four existing article
cases failed. The refresh path duplicated initial text fetching and asked older
API adapters for an unavailable episode lookup. Preparation now resolves text once
in the service, and adapters without the progress interface retain cached playback.
The original assertions remain unchanged. All 56 assistant, 17 media-browser,
eight saved-preparation and 16 voice-conversation tests then passed, followed by
all four article-service cases. Across that run and these focused reruns, 241
unique emulator cases are covered with no remaining failures or skips.
The subsequent Swift integration is described below. Physical-device acceptance remains open.

The final Android gate builds both debug APKs and passes all 219 JVM tests, with
no compiler warnings or lint errors. Eight existing lint warnings and one hint
remain. No backend or Swift implementation changed during this Android player
milestone; their contract-verification results above still apply.

## iOS shared article playback and cross-platform coordinates

The Swift player now uses the shared text bookmark, with a durable journal scoped
to the server and signed-in session. Explicit Play refreshes the selected text and
bookmark; matching cached text and local progress support an offline restart.
Preparation alone creates no zero-position report. Pause, switching articles and
completion retain the outgoing text identity, and modern articles cannot also send
a legacy seconds report. Newer server changes block old samples. Confirmed filing
blocks queued progress, and sign-out retires reporting before clearing the journal.
Android's durable pre-command filing guards and request recovery remain Android
features; this change does not add those command journals to iOS.

Both clients check the same exact Unicode text hash and UTF-16 bookmark, including
an emoji before and within the resumed passage. Different Android rendered
durations and Swift estimated seconds resolve to that same passage. The Swift
splitter also preserves original whitespace between sentences, preventing dropped
speech and incorrect coordinates in long paragraphs.

Final verification on 17 September 2026: 575 Swift tests pass, with one existing
opt-in recorded-audio benchmark skipped. The initial expanded run exposed a
completion test using another parallel test's sign-in state; injectable session
identity isolates the fixture, and a new regression verifies that queued reports
cannot borrow a new account's credentials. The final compile check has no warnings.
The test build reported 13 missing cached precompiled-module warnings, separately
from its passing results. Android passes all 220 JVM tests, builds both debug APKs
and passes lint with no compiler warnings or lint errors; eight existing lint
warnings and one hint remain. The prior 241-case emulator coverage still applies
because this final Android change adds only a shared-coordinate unit test.

## Per-item filing controls

Visible item menus now expose read/unread or played/unplayed, dismissal from
Latest and restoration. The same actions are available to accessibility services;
article swipe shortcuts remain optional. Search results and the reader expose
the actions too. Sample changes are acknowledged after an atomic local write,
and finished samples leave Latest while remaining available in their publication.

Signed-in actions use the existing typed request journal and shared execution
lease without AI permission. Duplicate taps cannot repeat a mutation. A lost
reply retains its original request ID for the Retry change button or Ask Magpie
recovery after reopening. Playback holds and progress guards prevent the old
clock from undoing filing, while account changes reject late replies. An explicit
unread/unplayed action clears the local bookmark and stops affected playback;
Undo keeps its existing bookmark-restoration behavior.

Verification on 17 September 2026: the full Android emulator suite passes all
249 tests without failures or skips. Eight filing journeys cover list/reader
actions, podcast playback, article bookmarks, restoration, lost replies, fresh
repository recovery, duplicate taps, account changes, shared request ownership,
and search at 200% text size in dark mode. The menu screenshot was visually
inspected. After separating explicit unread from Undo's bookmark restore, all
eight filing, 16 voice-conversation and six navigation tests passed again.
The final Android gate passes all 220 JVM tests and builds both APKs without
compiler warnings or lint errors; eight existing lint warnings and one hint
remain. Phone and TalkBack acceptance remain separate.

## Listening status and publisher metadata

Latest now separates Continue listening from new items while displaying each item
once. Completed and dismissed items are excluded from that section. Library rows
show preparing, playing or paused state, remaining podcast minutes and a progress
bar. The active podcast uses Media3's measured duration; reaching its final minute
is not treated as completion. Article progress uses the matching text bookmark,
including Unicode coordinates, without converting rendered seconds to a shared
article clock. Finished articles say Read; finished podcasts say Played.

Publication dates follow the reader's locale and time zone in library rows and the
article header. Publisher HTTPS artwork appears in Following, publication headers,
library rows, both players and Media3 metadata. Missing artwork keeps a decorative
placeholder. Account caches and recovered typed receipts retain the additive date
and image fields, and old snapshots remain readable. No backend or Swift contract
changes were needed for this item.

Verification on 17 September 2026: all 225 JVM tests and 254 emulator tests pass,
with no failures or skips. Five metadata journeys cover live playback with a
measured duration that differs from feed metadata, pause/seek, Continue listening,
completion/dismissal labels, cache persistence, account changes, additive decoding,
unsafe artwork rejection and large text in dark mode. The 200% text screenshot
was visually inspected. Image rendering uses a deterministic fixture loader in
these tests; it does not establish every publisher's image availability.
All five metadata journeys passed again after the final preparation-label polish.
Both debug APKs build without compiler warnings or lint errors. Eleven lint
warnings and one hint remain: eight warnings and the hint predate this item;
three recommend newer Coil versions. Coil 3.3.0 is intentionally used because its
Kotlin version matches this project's compiler. Phone and TalkBack acceptance
remain separate.

## Incremental article narration

Article playback now prepares only the passage containing its saved text bookmark
before starting. Media3 loads subsequent passages on demand. The old 30,000-character
limit and full-article WAV join are no longer part of playback. The same installed
offline voice policy applies; no network speech fallback was added.

The article remains one item in the shared player, notifications and assistant
controls. Its individual passages form periods in one Media3 window. Unprepared
passages initially have estimated durations, replaced by measured durations as
audio becomes available. Bookmarks use original text coordinates, and reading
highlights use the player's actual period offsets and the voice's word markers.
A seek near the end does not synthesize all earlier passages. Looking up the
current bookmark does not allocate the entire article timeline on every tick.

The disposable cache retains six complete audio passages, plus any files still
being read and one passage being prepared. Seeking can regenerate evicted audio.
Only complete WAV files become readable. Closing, replacement and account changes
cancel pending work, shut down the voice and remove temporary files. Cancellation
also releases a file prepared just as its reader was cancelled. A failure while
preparing a later passage reports a playback error and never marks the item read.

Verification on 17 September 2026: all 261 emulator tests pass with no failures or
skips. Six deterministic tests demonstrate long-article playback before later
audio exists, resume beyond 35,000 characters, backward seeking, a single media
item/window, bounded cache storage, active reader protection, startup and loader
cancellation, and failure without completion. The installed offline Google voice
also passes five shared-bookmark journeys, including a long article resuming
beyond the former limit and account-change cleanup. Existing reader, completion,
assistant, filing, interruption, speed and sleep tests pass in the full suite.
The Android gate passes all 225 JVM tests and builds both APKs without compiler
warnings or lint errors; the existing eleven lint warnings and one hint remain.
Audible transition quality, latency, battery use and long screen-off sessions
still require phone acceptance.

## Reliability diagnostics

Spoken attempts now report coarse outcomes and capture/response timing through the
existing authenticated voice-event contract. Local transport/sleep commands,
empty recognition, permission denial, cancellation and errors are represented.
Typed requests do not create spoken-attempt records. A backend command and its
voice summary share a trace ID. No transcript, audio, title, exception message or
stack enters these payloads, and unavailable microphone-buffer timing is omitted.

The private queue survives recreation, holds at most 50 reports per account for
30 days, and is excluded from device backups. Reports retry without interfering
with playback. Account/session checks surround disk and network work, and
acknowledgements retain recent event IDs to avoid re-queuing an acknowledged
crash. Sign-out and the new Share app diagnostics setting clear pending reports.
Samples do not upload diagnostics. The privacy page documents Android behavior.

Java/native crash and fatal unresponsive-app summaries come from Android's process
exit history after restart. A random marker in the OS record refers to private
account, credential and version information; only a matching session can report
that exit. Raw OS traces and descriptions are never read. A separate watchdog
reports recovered foreground main-thread freezes of at least five seconds,
excluding background, screen-off and debugger sessions. Activity visibility is
tracked from application startup so opening the library later still works.

Unit coverage checks queue bounds, expiration, retries, account switches, late
replies, original crash versions, private OS markers, timing and trace correlation.
Emulator coverage checks authenticated wire payloads, disk/marker recreation,
settings persistence and opt-out, a real controlled foreground freeze, and the
settings control at 200% text size in dark mode. Crash-history attribution uses
fixtures; it does not claim a physical-device crash or ANR test.

Verification on 17 September 2026: all 266 emulator tests pass with no failures or
skips, including the five new diagnostics journeys. The 200% text/dark-mode
screenshot was visually inspected. All 240 JVM tests pass; both debug APKs build
without compiler warnings or lint errors. Eleven existing lint warnings and one
hint remain. Backend checks pass 1,014 backend and 96 repository-script tests.
The diagnostics feature uses the existing API without changing Swift contracts.
All sixteen implementation items are now checked; physical-device acceptance,
release configuration and deployment remain separate.
