# Saved articles

Magpie accepts web links through Saved → Add link and the iOS share sheet.
Existing articles and podcast episodes can be saved from their detail screen.
Saved has To read and Finished views, search, retry, remove, and the existing
reader/player. Finishing an item keeps it in Finished.

## Capture and storage

The app and share extension share `group.com.henrydashwood.hearful`. Each pending
capture is an atomic, protected file tagged with the account and backend address.
No session credential is put in this container. The share sheet confirms local
storage; opening Magpie syncs captures and downloads prepared text. The inbox
removes a file only after the server acknowledges it. Original save dates survive
offline capture. Signing out clears that account's pending captures.

Safari preprocessing supplies page HTML after removing scripts, forms, and hidden
nodes and resolving relative links. Other apps generally supply a URL. Large
Safari pages fall back to URL capture. The backend extracts readable content and
sanitizes it. A failed extraction retains the link with an explicit Retry action.
Sites requiring login or JavaScript may need a Safari capture; full-text extraction
cannot be guaranteed for every publisher. PDFs, pasted text, and video transcripts
are outside this first implementation.

## Identity, content, and progress

- `episodes` remains the identity table. `feed_id` is nullable; `canonical_url`
  identifies standalone web saves. Private captured titles and bodies never go
  into the shared episode's metadata fields.
- `article_contents` stores immutable HTML/text pairs, title, capture source,
  digest, timestamp, and owner. An absent owner denotes shared content; this first
  saved-item path conservatively owns each capture by its saving user. Existing
  unsaved feed extraction continues to use the legacy cached article fields.
- `saved_articles` records each user's selected `content_id`, original save date,
  and any capture error. Removing from Saved clears its save date, retaining the
  selected copy for restoration. Account deletion erases private copies.
- Changed captures create additional versions. Duplicate captures within one
  owner and article reuse the existing version. Re-saving does not automatically
  switch the selected copy. A version picker and explicit refresh/switch UI are
  intentionally deferred.
- Progress includes `content_id`. A report for a different selection is rejected;
  an old client's unversioned tick cannot overwrite selected-version progress.
  Saving an existing feed article preserves its exact historical speech and
  progress. A different browser capture cannot inherit that speech's seconds.
- Offline text is keyed by episode and content version. Reading and playback use
  the same selected snapshot. Text availability is shown in Saved; images still
  require the network.

New public RSS ingestion reconciles a standalone article on a conservative URL
match, retaining the article ID, saved selections, and progress. Fragments and
default ports are normalized; meaningful query parameters are retained. Feed
metadata replaces only public identity metadata. This does not create a
subscription. Ambiguous titles and distinct URLs are not automatically merged.
One article has at most one feed association in this implementation.

Saved titles are included in visual and voice library search, scoped to the owner.
The voice search tool supports `saved_only`; save dates are provided as context.
The UI does not yet provide an automatic continuous Saved playlist.

## API

- `GET /saved` returns the user's saved episode payloads, newest save first.
- `POST /saved` accepts exactly one of `url` or `episode_id`, plus optional
  `title`, captured `html`, and timezone-aware `saved_at`.
- `POST /saved/{id}/retry` retries an item without captured content.
- `DELETE /saved/{id}` removes it from Saved without deleting playback history.
- Episode payloads add optional `content_id`, `saved_at`, and `capture_error`.
- `GET /episodes/{id}/text?content_id=…` returns an authorized immutable copy.
  Omitting the version resolves the user's selection, then legacy feed content.
- `PUT /episodes/{id}/position` accepts optional `content_id`.

Migration `c726d310e953` adds these tables and fields without rewriting historical
text. Downgrade refuses to discard standalone articles: export or reconcile those
first. Released client sources under `compatibility/` remain unchanged.

## Release setup

The new extension target is `HearfulShare`, bundle ID
`com.henrydashwood.hearful.share`, displayed as Magpie. Before distributing:

1. Register the app group and enable it on both the existing app and share
   extension App IDs.
2. Regenerate the app's distribution provisioning profile with the app group.
3. Create the share extension's distribution profile, and provide it to GitHub
   Actions as `APPLE_SHARE_PROVISIONING_PROFILE`.

The TestFlight workflow now installs and selects all three profiles (app, controls,
share extension). No credentials, developer-account configuration, release tags,
or production services are changed by this implementation.

## Verification

Run `make backend-check`, `make backend-compatibility`, `make ios-build`,
`make ios-test`, and `make ios-test-latest`. Focused tests cover privacy across
accounts, capture deduplication, immutable selection, mismatched progress, failed
extraction/retry, feed reconciliation, newsletter retention, account deletion,
private search, migration preservation, durable local capture, and cache versions.

A physical-device share-sheet check is still required before release, especially
signed-in Safari capture, offline saving, VoiceOver, and the new provisioning
profiles.
