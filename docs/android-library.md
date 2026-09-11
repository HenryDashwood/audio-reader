# Android account library

The Android client uses the existing backend contracts; no backend migration or
released Swift baseline changed. `MagpieApplication` owns the account session and
`AccountLibrary`, shared by the UI and playback service. The encrypted session
is never sent to article images, embedded sites, or podcast audio hosts.

## Loading and account boundaries

- Following uses `GET /feeds`, preserving feed IDs even when names match and
  showing feeds that contain no episodes.
- Latest uses `GET /episodes?limit=30`, respecting the server's latest cursor,
  played state, and dismissed state.
- Saved uses `GET /saved` and preserves server order and selected `content_id`.
- Feed pages use the newest 50 episodes and server-side search. Library search
  uses `/search/episodes`; an older query cannot replace a newer result.
- Article opening/playback fetches `/episodes/{id}/text?content_id=...` on demand.
  Text and HTML stay separate. The returned episode and selected version must
  match the request. Speech bookmarks use a digest of the full immutable text.

Signing in immediately removes samples from the visible library. Signing out,
deleting an account, or switching sessions clears account lists, reader state,
and playback. Replies carry a session revision and cannot restore an old account.
Item/bookmark IDs include a digest of the API server and authenticated user ID.
A 401 invalidates only the exact token rejected by the server.

An unsuccessful initial load displays a connection/error state, never samples.
An unsuccessful refresh retains only the current account's in-memory data.
The refresh button retries the library and current feed/search. Account metadata
and article text are not persisted for offline use yet.

## Actions and playback

Save/remove, URL capture, read/unread, Clear Latest, and subscribing to a direct
feed URL use the existing authenticated endpoints. UI state changes only after
the server accepts a write. Signed-out preview actions keep using their local
stores; pending links and feed addresses are never uploaded automatically.

Podcasts play the supplied HTTPS audio URL, resume from the saved server position,
and report media seconds on pause and every thirty seconds. During a playback
session, local positions preserve a just-paused place when reopening an item.
Completing a podcast or article updates played state. Article narration seconds
are never sent to the server's `position_seconds`: Android keeps a separate
local UTF-16 bookmark because voice timing differs across platforms.

Offline account caching, a durable retry queue for edits/progress, cross-device
article bookmarks, website feed discovery, directory search, source combining,
separating/unsubscribe, artwork loading, and physical-device acceptance remain
follow-up work. The existing full-article narration length guard still applies.

## Verification

The instrumentation runner supplies a separate test application with an in-memory
signed-out session. Fixtures exercise live-library behavior without reading the
owner's token or modifying the owner's account. `LiveLibraryTest` checks feed and
Saved navigation, pinned article text, podcast resume, account-change playback
cleanup, and JSON optional fields. JVM tests cover late replies, account/server
separation, failed reads/writes, latest semantics, search races, and rejection of
article seconds at the podcast position boundary.

Validated on 12 September 2026:

- `make android-check` passed: 52 JVM tests, both debug APKs, and lint; no
  compiler warnings were reported.
- The full API 36 emulator run passed 45 of 52 tests initially. Seven screenshot
  checks failed because the Android CLI inspection helper held the UI automation
  connection. After stopping that helper, AppearanceTest (2), ArticleReaderTest
  (7), and MiniPlayerTest (3) passed. LiveLibraryTest (4, including the added
  initial-load retry case) also passed. Across the full run and focused reruns,
  all 53 distinct instrumentation tests passed.
- The updated APK was installed over the emulator app. Google sign-in restored
  the staging account, with both Apple and Google connected. Following showed
  actual subscriptions; Ahead of AI opened its 21 posts; Latest loaded current
  items. Saved showed one unread article and three finished articles. Opening
  the unread article loaded its formatted full text. Following and reader
  screenshots were visually inspected. Live verification did not invoke library
  edits or playback; writes and podcast progress were exercised with test fixtures.
- Physical-device, TalkBack, Bluetooth, and offline voice acceptance remain
  unverified. No production deployment was performed.
