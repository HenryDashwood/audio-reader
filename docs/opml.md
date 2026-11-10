# Subscription import and export (OPML)

Both clients import and export subscriptions through the shared backend.
Deployment and distribution follow the [backend](backend-releases.md) and
[mobile](mobile-releases.md) release guides.

## Scope and flow

**Following → Add sources → Import subscriptions**, also available under
**Settings → Library**. The system document picker accepts OPML/XML files,
including files labelled with a generic document type. The server validates the
contents, not the filename. No connection to the exporting app is needed.

1. Choose an export from a podcast or RSS reader app.
2. Review plain-text titles and hostnames and select subscriptions. No public-feed
   confirmation is required. Known follows are disabled. Exact duplicates
   are collapsed; folders are flattened. Lists over 20 entries can be searched.
3. Start importing. Progress persists on the server, including after the app
   closes. Reopen Import subscriptions to recover the current job.
4. Review added/already-following/failed counts. Retry failed entries, stop an
   active job, or choose another file.

Subscriptions only: no played/read state, playback positions, folders,
highlights, email delivery, paid-access transfer, or app account connections.
RSS feeds of newsletters are ordinary publications. Overcast episode extensions
are ignored; explicitly unfollowed (`subscribed="0"`) shows are skipped.

New subscriptions use Magpie's existing Latest watermark: older items remain
on the subscription page, while future items enter Latest. Existing follows,
watermarks, and listening/reading state are preserved.

## Public and private feeds

An imported feed is shared only when its origin homepage advertises the exact
feed URL through HTML feed metadata or an HTTP Link header, the feed does not
redirect, and the URL has no personal-address hints. All query strings,
credentials and long opaque path/host components are conservative private hints.
A failed or blocked homepage check leaves the feed private and does not block
importing. A token-free URL alone is never proof that content is public.

Private feeds use the existing `Feed.owner_user_id` access boundary. Their
`Feed.url` is an opaque `private-rss:` identity; the new nullable
`private_fetch_url` retains the original address for polling. It is never
serialized as a shared feed address. Two accounts using the same private URL
receive distinct feeds, episodes and article caches. Account merges retain both
copies rather than losing saved state. The original URL remains authoritative:
redirects and `rel=self` cannot downgrade privacy or replace credentials.
Private imports bypass shared discovery caches, aliases and standalone-article
reconciliation. Known private URLs deduplicate within the owning account.
Different URLs that redirect to the same address remain distinct private feeds.

HTTPS Basic-auth feed URLs and bearer URLs in paths or queries are accepted.
Basic credentials are not forwarded across origins or HTTPS downgrades.
Local-network destinations, invalid schemes and nonstandard ports remain
blocked, including after redirects. Paid access must already be conveyed by the
feed link; importing does not transfer a purchase or sign into another app.
Separate authentication required by a media enclosure is not supplied by this
feed importer.

Private feeds are polled while followed. They participate in the normal orphan
retention policy and are deleted with their owner's account. Private ingestion
skips additional artwork discovery requests. Results identify private additions
as “Imported privately”. Existing feed and episode access checks apply to reading,
search, saving and playback; subscription staging also checks the owner.

Raw XML is parsed in memory and is not retained. Drafts retain eligible URLs
for 24 hours; accepted job records are retained for seven days. Expired records
are inaccessible and removed by the worker. Account deletion cascades to jobs
and items. Import responses expose titles and hostnames, not full URLs.
Feed/article GET requests suppress outbound HTTP instrumentation and HTTP client
URL logging, since opaque path tokens cannot be reliably redacted. Fetch errors
and article-extraction logs omit the request URL.

## Shared API

All endpoints require the initiating account's authentication:

- `POST /subscription-imports/preview`: bounded raw `application/xml` body,
  returns a durable draft. Does not fetch publishers or create subscriptions.
- `GET /subscription-imports/current`: active job first, otherwise the latest
  retained draft/result, or `null`.
- `GET /subscription-imports/{id}`: account-owned job and item outcomes.
- `POST /subscription-imports/{id}/start`: `request_id`, selected `entry_ids`,
  returns 202. The legacy `public_feeds_confirmed` field is accepted but ignored.
- `POST /subscription-imports/{id}/stop`: stops further subscription commits.
- `POST /subscription-imports/{id}/retry`: `request_id`; creates a new job for
  retryable failures only, preserving publisher delay.

Start/retry request IDs provide replay protection. A unique active-account key
allows only one active job per account. Jobs transition from draft to queued,
running, then completed or stopped. Item receipts distinguish pending,
processing, added, already-following, failed, and stopped. Invalid review rows
remain visible but cannot be selected.

The clients freeze uncertain start requests and reuse their original request
ID and selection after a lost reply. File reads and responses remain bound to
the initiating account/server; switching accounts invalidates pending UI work.

## Execution and limits

The application lifespan runs a small database-backed worker. A global database lease permits one import fetch chain across server processes.
A lease lasts 120 seconds; each preparation is limited to 60 seconds. A stale
worker cannot commit a follow after losing its lease. Process death leaves a
recoverable processing item. The worker waits at least two seconds between
items; publisher Retry-After delays extend the global cooldown. This deliberately
favours conservative publisher traffic over bulk throughput.

Import fetches use the existing public-network checks, bounded fetching and
feed parser, followed by privacy classification. Catalogue preparation may commit
before a follow, but the follow and its terminal item receipt commit atomically.
Stop takes the same job write lock as that final transaction, preventing later
subscription commits after stop is acknowledged. An already-imported item is
never replayed after a deliberate unfollow.

Transient failures receive up to three automatic attempts, then become
retryable results. Non-finite or longer-than-one-day publisher delays are
terminal for that item, preventing timestamp overflow or indefinite global
stalling; those items are not automatically retried. Failures do not discard successful entries. A very long
publisher delay blocks other import fetches too; per-host scheduling is a
future scalability improvement. API reads and normal app actions continue.

Limits: 5 MiB XML, 2,000 entries, 32 levels, 20,000 XML nodes, bounded attribute
sizes. DTDs and entities are rejected; XML text is never interpreted as commands.
Malformed XML rejects the whole review. UTF-8/BOM and UTF-16 are covered.

## Verification and fixtures

See `backend/tests/fixtures/opml/README.md` for source provenance. The corpus
combines a trimmed real public AntennaPod export with explicitly synthetic
Overcast extensions, reader folders, and mixed podcast/publication files.
Generated tests cover Unicode, missing titles/addresses, exact duplicates,
unsafe URLs, malformed XML, entities, maximum sizes, and maximum nesting.
These samples do not establish verified compatibility with every exporting app.

Backend tests also exercise the actual mocked HTTP feed pipeline, redirects,
private redirect isolation, podcast/publication classification, private-network
redirect rejection, replay, account isolation, stop during fetch, worker crash
recovery, stale leases, partial failure/retry, expiry, Latest watermarks, and the
migration's preservation of subscriptions/account-deletion cascade.

Native tests cover request contracts, bounded file reads, lost-response replay,
account changes, and recovering server jobs. Android instrumentation covers
entry points, starting without confirmation, stopping after reopening, and large-text dark mode.

Required release checks: `make backend-check`, `make backend-compatibility`,
`make ios-build`, `make ios-test`, `make ios-test-compatibility`, `make android-check`,
and the Android instrumentation tests. Tests use isolated data and mocked
publishers; they do not subscribe a real account to public fixture feeds.

Before claiming app-by-app compatibility, collect fresh consented exports from
Pocket Casts, Overcast, Castro, Podcast Addict, Feedly, Inoreader, NetNewsWire,
NewsBlur, and Readwise Reader. Redact private URLs and record app/version/platform.
Physical-device Files/provider behaviour and VoiceOver/TalkBack also need a
release smoke check; simulator/emulator tests do not establish that coverage.

## Subscription export

Settings → Library now has **Export subscriptions** directly below Import on
iOS and Android. The export screen explains what the file includes and opens
the system file saver for `Magpie-subscriptions.opml`.

`GET /feeds/export` requires the current account and returns UTF-8 OPML 2.0
with attachment and `Cache-Control: no-store` headers. It exports all followed
RSS sources, including children of combined publications and the RSS companions
of followed email newsletters. Exact URLs appear only once. Email-only sources,
reading/listening state and folder/group organisation are not exported. Empty
libraries receive an explanatory error instead of an unusable empty file.

Personal feed links use their original address, never the internal private-feed
identifier. The account ownership filter applies even if a subscription row is
inconsistent. The file therefore contains any credentials needed by personal
feeds, as the export screen explains. No publisher is contacted during export.
Unicode, XML escaping, malformed optional homepage metadata and illegal XML
characters in titles are covered by the round-trip tests.

Both clients capture the initiating account, reject late responses after account
changes, and use native document pickers. Android retains pending XML only in
ViewModel memory across activity recreation; it is cleared on account changes
and is not written to saved app state. Once saved, the file is a normal document
the user can share or import elsewhere.
