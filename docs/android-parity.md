# Android parity checklist

Baseline: source review against the current iOS app, 11 September 2026.
Updated: 16 September 2026.
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
- [ ] **8. Assistant and shortcuts.** Android equivalents of the iOS hands-free actions.
  Launcher/pinned actions, Quick Settings, account-scoped Continue listening,
  trusted Ask microphone launches, media-client library browsing/search, structured
  lookup/status, playback controls, and structured filing/Undo are implemented.
  Free-form requests, subscriptions, and destination actions remain; the newsletter action also depends on item 9.
- [ ] **9. Newsletters.** Address presentation/sharing, sender approval/blocking, and signup.
- [x] **10. AI consent controls.** The discovery flow discloses AI data sharing
  before granting permission. Settings reads, reviews, grants, and withdraws the
  same backend account permission used by iOS. Declining never runs an AI search.
  Implemented alongside item 3 because web discovery depends on it.
- [ ] **11. Progress sync and offline content.** Account-scoped caches and backend
  progress reporting. Do not send rendered Android article seconds through the
  existing position API; its timeline differs from the iOS article timeline.
  Podcast reporting is implemented; persistent caches, a durable retry queue, and
  cross-device article bookmarks remain.
- [ ] **12. Per-item filing.** Played/unplayed, read/unread outside Saved,
  individual Latest dismissal, and restoration. Saved read/unread and Clear Latest
  already update the backend.
- [ ] **13. Listening status and metadata.** Continue listening, live progress,
  completed/current-item labels, publication dates, and publisher artwork.
  Shortcut/tile continuation is implemented with item 8; the in-app presentation
  and remaining metadata still need work.
- [ ] **14. Article startup and length.** Avoid full upfront synthesis and the
  30,000-character guard, with cancellation and stable text bookmarks preserved.
- [x] **15. End-of-item behavior.** Completing a podcast or narrated article marks
  it finished (on the backend when signed in), resets its replay bookmark, clears the player and timer,
  and plays a completion tone. Saved updates without reopening. Pausing or
  manually closing an unfinished item preserves its bookmark and does not mark it
  finished. Live Latest respects server filtering. Remaining per-item filing and
  status presentation are tracked in items 12–13.
- [ ] **16. Diagnostics.** Account-connected voice attempts and crash/hang reporting.

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

Item 8 remains unchecked until free-form requests,
subscription, and destination actions are implemented and verified. Future assistant adapters
must preserve the trusted microphone launch boundary and Android permission step.
Newsletter shortcut support also depends on item 9. Platform-specific release
and physical-assistant acceptance remain separate from emulator verification.

## Shared limitations

Podcast downloads and offline article images are not counted as Android parity
gaps because the reviewed iOS implementation does not provide them either.
Physical TalkBack, Bluetooth, narration quality, and completion-tone audibility
still need intentional phone acceptance testing.
