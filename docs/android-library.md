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
stores; sample pending links and feed addresses are never uploaded automatically.
Signed-in saved links use the account-scoped queue described below.

Podcasts play the supplied HTTPS audio URL, resume from the saved server position,
and report media seconds on pause and every thirty seconds. During a playback
session, local positions preserve a just-paused place when reopening an item.
Completing a podcast or article updates played state. Article narration seconds
are never sent to the server's `position_seconds`: Android keeps a separate
local UTF-16 bookmark because voice timing differs across platforms.

Offline account caching, a durable retry queue for edits/progress, cross-device
article bookmarks, artwork loading, and physical-device acceptance remain
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


## Source discovery

`SourceDiscovery` owns cancellable, generation-bound search and preview state in
`MagpieModel`. `HttpLibraryApi` also implements `DiscoveryApi`, using existing
`/search/podcasts`, `/search/episodes`, `/feeds/discover`, `/feeds/preview`, and
`/search/publications` contracts. Preview items join the account-scoped item cache
for reading/playback, without changing Following, Latest, or Saved. Existing
saved items retain their selected content version. A preview carries its session
revision; it cannot be subscribed under another account. A subscription conflict
is accepted only after refreshing and confirming that the feed is followed.

Directory and account searches are independent so one failure keeps the other's
results. Addresses bypass both and are discovered only on explicit submission.
The web fallback is an explicit action and reads current account AI permission
before submitting a query. Missing consent presents a disclosure; allowing it
uses `/me/ai-data-sharing`. Settings can review and withdraw the same account
permission. Voice capture itself remains unimplemented on Android.

## Source management

`SourceManager` owns the management dialog and serializes UI actions. Existing
`GET /feeds/{id}/sources`, `PUT /feeds/{id}/sources/{source_id}`, and corresponding
DELETE endpoints provide source listing, combination, separation, and unsubscribe.
The backend retains ownership of duplicate selection and shared progress; Android
does not merge article records or infer groups from matching names.

Every operation carries the current session revision. Successful writes invalidate
old feed/search replies and refresh Following, Latest, and Saved. The feed page
reloads after grouping changes and returns to Following when unsubscribed.
Cached text, item IDs, bookmarks, and playback remain available. Known word counts
survive metadata refreshes, and absent feed URLs cannot match unrelated feeds.
A failed write keeps the existing group; a confirmed write followed by a failed
refresh is reported as a refresh failure, with a retry to reload the group.

Source rows distinguish the primary source, email newsletters, hosts, and update
failures. Private subscription URL paths and tokens never appear in those labels.
Only non-primary sources can be separated. Unsubscribe also works in a subscribed
preview; removing a combined root stops following every source in the group.

## Saved article preparation

`ArticleInboxStore` commits URL, stable capture ID, and original saved timestamp
to app-private storage before acknowledging a capture. Queues are partitioned by
the server/user digest, separate from signed-out sample inboxes. A server-bound
token digest remembers the last identified account for offline cold-start capture;
it stores no credential and cannot identify a different token or server. Account
metadata and full article text remain in memory.

`SavedPreparation` syncs pending links on account activation, entering Saved,
refresh, or explicit retry. It runs in the foreground and has no background worker.
Only a confirmed `/saved` response removes a pending entry. Transport failure
keeps the entry and its timestamp for an idempotent retry. A response containing
`capture_error` is a saved link, with explicit Retry and Open original actions.
Pending entries can also be removed when no sync is in flight.

Saved offers Review device links for URLs captured before sign-in. Cancelling
leaves them unassigned. Confirmed import commits each link to the chosen account
queue before removing its device-inbox copy. If an import fails partway through,
the remaining device links stay available; account changes stop the import.

Retry uses `/saved/{id}/retry`; confirmed replacement uses `/saved/replace`.
The existing backend owns immutable content selection and replacement failure
semantics. Android invalidates loaded text only when the selected content changes,
rejects stale text/search replies, and keeps the selected Saved version when
loading feed results. The playback service cancels old narration, preparation,
and timers when it observes a new content ID; local text bookmarks are reset.
An unchanged selection keeps playback and its bookmark. Failed replacements keep
the current copy and can be tried again. Account changes dismiss confirmation,
hide other accounts' pending links, and prevent late replies from altering them.
Filing updates from an older content ID are rejected, so a late playback completion
cannot mark replacement text as read. An empty Following search preserves initial
load errors even when a cached account identity is available for offline capture.
