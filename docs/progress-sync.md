# Progress synchronisation

The released `PUT /episodes/{id}/position` contract remains available with its
existing seconds-based behaviour. Android article narration must not use it:
local speech engines and iOS article estimates have different timelines.

## Guarded podcast progress

Podcast episode responses now include optional `progress_revision`. It is an
opaque token tied to the listener, episode and effective playback/filing state,
including grouped copies. Older servers omit it; articles return null. Current
Swift and Android episode models tolerate its absence. The current Swift reporter
continues to use the released endpoint.

`PUT /episodes/{id}/progress` accepts:

```json
{
  "request_id": "a-client-generated-unique-id",
  "expected_revision": "64 lowercase hexadecimal characters from the episode",
  "position_seconds": 125.5,
  "completed": false
}
```

The request ID and entire body must remain unchanged after dispatch, including
when the connection closes before the reply. Seconds must be finite and
nonnegative. This endpoint rejects articles and inaccessible episodes.

A successful response contains `accepted_revision` and `episode`, using the
ordinary episode response shape. The position and request receipt commit in one
transaction. Repeating an accepted request acknowledges it without writing again.
A reused request ID with a different payload is rejected. The episode in a retry
reply reflects current state, which may have changed since the original request.
Compare its `progress_revision` with `accepted_revision` before sending any later
locally queued clock: a difference means a newer action must be preserved.

An unaccepted request whose comparison token is stale returns HTTP 409 with
`detail.code` equal to `progress_changed`. Reload the episode and keep its newer
state; do not simply replace the expected revision and resend the old position.
Filing, legacy position writes, grouped-copy changes and linking invalidate stale
tokens. Playback, filing and grouping writers serialize on the user's database
row, including the first write when no position row exists.

Accepted receipts older than seven days are cleaned up on a subsequent successful
report. An expired receipt still cannot repeat an old write: its previous
comparison token no longer matches. Account deletion removes receipts; linking
retires the merged-away account's receipts and retains those of the surviving
account. Migration `ba739cf18a02` adds only the receipt table.

## Guarded article bookmarks

The additive article contract and both native player integrations are implemented.
Modern Swift and Android playback save and resume shared text bookmarks; Swift
retains its seconds reporter for older servers that omit the article capability.

Android explicit Play fetches the current selected text and bookmark even when
text is cached, with a matching offline snapshot as fallback. The service resumes
at the containing narration chunk, so a different voice or chunk size may repeat
a few words but does not skip unheard text. Actual playback writes an immutable
request to an account-scoped article journal and keeps subsequent samples separate.
Completion sends the final UTF-16 coordinate through the guarded route without a
second legacy filing request. The article journal shares podcast filing guards,
network drains, foreground retries, and sign-out cleanup. A changed server revision
blocks the old playback session rather than rebasing its old bookmark.

`GET /episodes/{id}/text` now includes optional `article_progress` with the exact
text's SHA-256 `text_version`, selected `content_id` (nullable for feed text),
`revision`, and a matching `bookmark` when one exists. The digest uses the exact
UTF-8 text with no normalization. The bookmark's `offset_utf16` is a Unicode
scalar boundary in that text, shared by Swift's NSString ranges and Kotlin's
string indices. It is independent of rendered audio seconds and speech speed.
Explicitly fetching an older, unselected saved snapshot still returns its text
but does not advertise permission to replace the account's current bookmark.

`PUT /episodes/{id}/article-progress` takes immutable `request_id`,
`expected_revision`, `text_version`, `content_id`, `offset_utf16`, and `completed`.
It returns the current `episode` and `progress` plus the original write's
`accepted_revision`. Exact retries acknowledge without writing again; reused IDs
with changed payloads fail. A stale revision, changed text or changed selected
snapshot returns `409 progress_changed`. Out-of-range offsets and offsets inside
a surrogate pair are rejected. This route accepts only accessible articles.

The revision binds the effective filing/progress row and current selected text.
The write and receipt commit together. Receipts older than seven days are cleaned
up on a later successful write; their old comparison tokens still prevent replay.
Filing and grouped-copy changes invalidate old clocks. Unread/restore clears the
bookmark; Undo snapshots preserve it and reject newer bookmark changes. Replacing
saved text clears the old coordinate. A newer legacy seconds report also clears
the text bookmark, so it cannot mask an older client's newer listening. Account
linking preserves the winning position/bookmark and retires the removed account's
receipts; deletion removes private progress and receipts.

Migration `c725fe930a16`, after `ba739cf18a02`, adds two nullable bookmark columns
to positions and a separate receipt table without rewriting existing positions.
For older Swift clients, new text reports also supply a backend-derived estimate
at 170 words/minute. Modern clients must prefer a matching text bookmark; Android
must never send its rendered article seconds through the old position endpoint.
Episode summaries include optional `article_bookmark`; always compare its text
version with the actual loaded text before using its offset.

## Android integration status

Android playback uses the guarded route when an episode supplies a comparison
token. Older servers retain the legacy reporter. Article narration never uses
this route. The account/server-scoped journal lives in app-private storage outside
backup and disposable caches, using atomic replacement away from the UI thread.

An explicit Play creates a playback session with the revision known at that time.
Preparing media alone does not queue a zero position. While playing, the service
saves a sample every three seconds, and also saves on pause, close and completion.
A dispatched request keeps its exact ID and body; later samples coalesce separately
until acknowledgement permits a new request. Final service writes belong to the
application, so ordinary service teardown does not cancel their disk write.
Process termination can still lose the unsaved interval since the last sample.

Uploads run on pause/completion, at thirty-second intervals while the process is
alive, and after restoring the account. Offline failures retain the journal.
A known account restores its local clock over its cached library before refresh.
A fresh server response with another revision is preserved; background refreshes
never rebase the old request. A conflict blocks the old playback session, while a
new explicit Play can establish intent against the current canonical revision.
Completion is part of the guarded report, without a separate legacy filing write.

Manual filing blocks earlier queued clocks. Voice/assistant filing saves a guard
with the original request ID before waiting for in-flight progress and allowing
the server mutation. Matching confirmations release that guard; filing receipts
block the old playback session. Guards persist across reopening storage and cannot
be cleared by an unrelated confirmation or a new playback session. Sign-out clears
that account's journal, and late replies cannot repopulate it. Malformed journals
fail closed, preserving their files and allowing the cached library to remain
available with an error instead of forgetting filing guards.

Free-form and structured filing/Undo request journals restore original requests and receipts in
Ask Magpie. Explicit checking reconciles current state and releases that request's
guard; confirmed dismissal cancels unfinished work before refreshing and releasing
the guard. Typed requests retain their original action route and target; checking
an old Undo receipt never undoes a newer change. They share the same execution
lease as free-form requests and do not require AI consent.

## Verification

The complete backend gate passed 1,002 tests plus 96 repository-script tests.
The new cases cover retry acknowledgement after a later filing action, stale
reports after legacy writes, request-ID conflicts, receipt expiry, account
isolation/deletion, grouped copies, transaction rollback and migration reversal.
Account-linking tests also verify receipt retention/removal. These database tests
use SQLite; production row-lock exclusion relies on PostgreSQL's `FOR UPDATE`.

The frozen released Swift client compatibility gate passes. All 16 current iOS
`AuthAndPositionTests` pass on the configured iPhone 17 simulator. The build
reported 15 missing cached precompiled-module warnings; the corrected focused
execution had no failed or skipped tests. An earlier filename-based filter
selected zero tests and is not counted as coverage.

The Android gate passes 175 JVM tests, compiles both APKs and reports zero compiler
warnings or lint errors; eight existing lint warnings and one hint remain.
Two Android protocol tests check identical retries, authentication, conflict/error
handling, current versus accepted revisions and old-payload decoding. The cache
round-trip suite also retains the token across fresh storage instances.


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


Android article integration verification on 17 September 2026 covers 12 durable
queue tests, five repository cases, two on-device journal cases, and four service
cases, including a newer remote bookmark after the text was already cached.
The full emulator run initially had four article regressions; correcting duplicate
text loading and preserving older adapters' cached path resolved them with the
original assertions intact. The full run plus focused reruns cover 241 unique
cases without remaining failures or skips. The JVM suite passes all 219 tests.
Swift integration and the final cross-platform checks follow below.

## Swift integration

Swift explicit Play refreshes the selection and text bookmark after draining any
in-flight report. Matching cached text is available offline. The player validates
the exact UTF-8 hash and UTF-16 scalar boundary, and resumes at the containing
utterance. It captures the outgoing episode, content version and coordinate before
switching or clearing playback. Completion records the final text length. A
modern article cannot also send a legacy position or completion write.

The small atomic journal is outside disposable caches, excluded from backup, and
scoped by a fingerprint of the server and signed-in session. Samples are persisted
every three seconds and on pause, seek, backgrounding, switching and completion;
preparation alone reports nothing. Requests retain their exact body and ID across
offline restarts; later samples wait for acknowledgement. Foreground retries run
at startup and every thirty seconds while the process is alive. Process death can
lose the unsaved interval. Confirmed filing blocks old clocks, and conflict replies
preserve canonical progress. Sign-out invalidates reporters before deleting the
journal and changing credentials; late replies cannot restore it. Storage failures
and deferred or conflicting progress are visible in the player.

Swift does not yet have Android's durable voice/structured-request recovery
journal. Its confirmed filing notifications block queued bookmarks, while the
server's revision comparison rejects an old bookmark after a newer mutation.

Final cross-platform verification: both native suites use the same accented/emoji
text, SHA-256 digest and UTF-16 passage coordinate. Android's differing rendered
voice durations and Swift's estimated timeline resume that same passage. Ten
Swift journal tests and five player integration tests cover durable exact retries,
account invalidation, newer filing, changed text, natural completion and switching
items. All 575 Swift tests pass, with the existing optional recording benchmark
skipped. The final iOS build has no warnings; the test build separately reports
13 missing cached-module warnings. Android's final gate passes 220 JVM tests and
both APK builds, with no compiler warnings or lint errors (eight existing lint
warnings and one hint). Native phone audio and a live two-device journey remain
release acceptance checks; these results use isolated fixtures.
