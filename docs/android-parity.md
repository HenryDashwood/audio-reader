# Android parity checklist

Baseline: source review against the current iOS app, 11 September 2026.
Updated: 15 September 2026.
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
- [ ] **4. Source management.** Combine, separate, and unsubscribe.
- [ ] **5. Saved article preparation.** Process pending links, retry failed captures,
  and replace saved text. URL capture and retry-on-open are implemented; pending
  inbox processing and explicit text replacement remain.
- [ ] **6. Incoming sharing.** Receive shared links and support browser content capture.
- [ ] **7. Ask Magpie conversations.** Recognition, commands, spoken replies,
  follow-up conversations, and timing preferences.
- [ ] **8. Assistant and shortcuts.** Android equivalents of the iOS hands-free actions.
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

The next unchecked item is **4. Source management: combine, separate, and
unsubscribe**.

## Shared limitations

Podcast downloads and offline article images are not counted as Android parity
gaps because the reviewed iOS implementation does not provide them either.
Physical TalkBack, Bluetooth, narration quality, and completion-tone audibility
still need intentional phone acceptance testing.
