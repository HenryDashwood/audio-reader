# Android parity checklist

Baseline: source review against the current iOS app, 11 September 2026.
Numbers match the review. A checked item covers the implementation described
here; emulator results do not establish physical-device audio or TalkBack quality.

- [ ] **1. Accounts and live library.** Sign-in, sessions, sign-out, account
  deletion, and account-backed library loading. Apple and Google are the chosen
  providers on both platforms, with explicit account linking. Apple browser sign-in,
  Google sign-in,
  secure sessions, and account controls are implemented; see
  [sign-in setup](sign-in.md). Provider setup and live acceptance checks are still
  required. Live library loading remains unfinished. Keep sample content isolated.
- [ ] **2. Real podcast playback.** Play publisher audio URLs instead of the bundled recording.
- [ ] **3. Discovery and subscribing.** Directory/web search, feed discovery,
  previews, and subscriptions.
- [ ] **4. Source management.** Combine, separate, and unsubscribe.
- [ ] **5. Saved article preparation.** Process pending links, retry failed captures,
  and replace saved text.
- [ ] **6. Incoming sharing.** Receive shared links and support browser content capture.
- [ ] **7. Ask Magpie conversations.** Recognition, commands, spoken replies,
  follow-up conversations, and timing preferences.
- [ ] **8. Assistant and shortcuts.** Android equivalents of the iOS hands-free actions.
- [ ] **9. Newsletters.** Address presentation/sharing, sender approval/blocking, and signup.
- [ ] **10. AI consent controls.** Review, grant, and revoke account-level permission.
- [ ] **11. Progress sync and offline content.** Account-scoped caches and backend
  progress reporting. Do not send rendered Android article seconds through the
  existing position API; its timeline differs from the iOS article timeline.
- [ ] **12. Per-item filing.** Played/unplayed, read/unread outside Saved,
  individual Latest dismissal, and restoration.
- [ ] **13. Listening status and metadata.** Continue listening, live progress,
  completed/current-item labels, publication dates, and publisher artwork.
- [ ] **14. Article startup and length.** Avoid full upfront synthesis and the
  30,000-character guard, with cancellation and stable text bookmarks preserved.
- [x] **15. End-of-item behavior.** Completing a podcast or narrated article marks
  it finished locally, resets its replay bookmark, clears the player and timer,
  and plays a completion tone. Saved updates without reopening. Pausing or
  manually closing an unfinished item preserves its bookmark and does not mark it
  finished. This does not yet add the Latest filtering/status in items 12–13 or
  backend reporting in item 11.
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

## Shared limitations

Podcast downloads and offline article images are not counted as Android parity
gaps because the reviewed iOS implementation does not provide them either.
Physical TalkBack, Bluetooth, narration quality, and completion-tone audibility
still need intentional phone acceptance testing.
