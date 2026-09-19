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

Safari preprocessing runs bundled Mozilla Readability on a clone of the loaded
page. It removes hidden content using Safari's computed styles before discarding
stylesheets, retains paragraphs below the fold, and resolves relative links.
Competing article bodies need a unique matching headline; ambiguous pages and
stale canonical URLs fall back to saving the current link. Publishers that split
one story into multiple article elements can retain their common article ID.
This uses the loaded page, not Safari's private Reader implementation.
Responsive images keep the browser-selected source before responsive attributes
are removed; unloaded images can use their declared lazy or picture sources.
Known Canary Media article layouts retain all prose sections, images, and
captions. Simon Willison sighting pages retain their short text and photo
galleries. These layout rules also apply to server-fetched saves. An unfamiliar
layout on these routes fails capture instead of saving navigation or a sponsor.
Other short illustrated articles can be retained when a single article body,
matching canonical URL, and article metadata identify the content. Generic
extraction checks substantial paragraphs in the selected article and rejects a
result that silently omits them; it does not merge unrelated page sections.

X/Twitter status links use a concise author-and-opening title (at most 100 Unicode
code points), while retaining the complete post body. Explicit article headlines
keep their normal title. The share preview and stored title use the same policy,
with shared regression cases; ordinary publisher titles are unaffected.

Archive.today-family short links can use a timestamped canonical URL on the same
origin when the page's unique Open Graph URL matches the shared short link.
This preserves the shared URL as the saved identity and still rejects stale or
ambiguous snapshot metadata.

The share sheet previews the extracted title and opening paragraph before Save.
Its single Save article action updates an existing saved copy by default, or
creates a new save when the server explicitly reports that none exists. There is
no replacement toggle. Changed text restarts listening; failed replacements keep
the current copy. A missing replacement route does not fall back to ordinary save.
Other apps generally supply a URL. Limits apply to the extracted article, so
large navigation sections do not discard an otherwise small article. Failed,
oversized, or uncertain extraction falls back to URL capture without truncation.
The backend sanitizes an identified browser article without re-extracting its
body, and verifies that its canonical URL matches the saved link. Legacy page
captures and URL fetches still use server extraction, with explicit hidden-node
removal and a guard against ambiguous competing articles. A failed extraction
retains the link with an explicit Retry action.
Sites requiring login or JavaScript may need a Safari capture; full-text extraction
cannot be guaranteed for every publisher. PDFs, pasted text, and video transcripts
are outside this first implementation.

If a site refuses the backend request (HTTP 401 or 403), Saved directs the user to
open the page in Safari and use Share → Magpie. Sharing the same URL with its page
content repairs the saved link, preserving its identity and original save date.
HTTP 429 refusals explain that the site may be limiting requests or requiring a
browser security check. They suggest trying later or sharing from Safari after
the full article is visible; Retry alone still performs a server fetch.

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
  switch the selected copy through ordinary saves. **Replace saved text** in a
  Saved item's context menu fetches a fresh copy from its original link. Safari's
  share sheet automatically queues a replacement using the previewed browser
  capture, useful for signed-in pages. Replacement requires an existing saved item owned by the user,
  preserves its original save date, and keeps the old immutable content version.
  A failed replacement leaves the selected copy and progress unchanged. Changed
  spoken text resets progress and completion; identical speech keeps progress,
  including after an offline replacement is delivered again. The client clears
  playback of a superseded version and reloads an open reader. A version picker
  remains deferred.
- Progress includes `content_id`. A report for a different selection is rejected;
  an old client's unversioned tick cannot overwrite selected-version progress.
  Saving an existing feed article preserves its exact historical speech and
  progress. A different browser capture cannot inherit that speech's seconds.
- Offline text is keyed by episode and content version. Reading and playback use
  the same selected snapshot. Text availability is shown in Saved; images still
  require the network (except embedded static chart images).

New public RSS ingestion reconciles a standalone article on a conservative URL
match, retaining the article ID, saved selections, and progress. Fragments and
default ports are normalized; meaningful query parameters are retained. Feed
metadata replaces only public identity metadata. This does not create a
subscription. Ambiguous titles and distinct URLs are not automatically merged.
One article has at most one feed association in this implementation.

Saved titles are included in visual and voice library search, scoped to the owner.
The voice search tool supports `saved_only`; save dates are provided as context.
The UI does not yet provide an automatic continuous Saved playlist.

## Artwork

New web and Safari captures keep the article's Open Graph share image, then its
Twitter card image, falling back to a declared site icon. Relative image URLs use
the fetched page's final address or Safari's original base URL. Unsupported SVG,
non-web, credentialed, and malformed image URLs are skipped. Feed artwork keeps
its existing publication-logo preference.

Captured artwork belongs to the private immutable content version and never
enters shared episode metadata. Replacing a copy can update its image without
resetting listening progress when the spoken text is unchanged. The existing
`image_url` response field carries the selected image, so clients need no new
JSON fields. Safari preserves the metadata inside its existing HTML envelope.

Saved articles with no captured or feed artwork, including older saves, try the
publisher's standard `/favicon.ico` directly. This does not fetch or replace their
text. Sites without a usable image retain the app's monogram placeholder. To
obtain a share image for an older copy, replace its saved text or share it again
from Safari. Image loading still requires the network.

Migration `a19d6e7f2c84` adds a nullable image URL to `article_contents`; historical
content, selection, and progress remain unchanged.

## API

- `GET /saved` returns the user's saved episode payloads, newest save first.
- `POST /saved` accepts exactly one of `url` or `episode_id`, plus optional
  `title`, captured `html`, timezone-aware `saved_at`, and `content_format`
  (`page`, the default, or `article`). An `article` envelope has one body-level
  article, its title, and a canonical link matching the save URL. All HTML is
  untrusted and sanitized regardless of format.
- `POST /saved/replace` accepts the same payload and explicitly replaces an
  existing saved selection. It returns 404 for an absent save and 422 for a failed
  replacement. It has its own route so older servers cannot silently ignore a
  replacement flag. No released-client payload or default save behavior changes.
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
`make ios-test`, and `make ios-test-compatibility`. Focused tests cover privacy across
accounts, capture deduplication, immutable selection, mismatched progress, failed
extraction/retry, feed reconciliation, newsletter retention, account deletion,
private search, migration preservation, durable local capture, and cache versions.
WebKit tests execute the bundled Safari script against hidden and competing
articles, split publisher markup, stale page identity, relative links, and large
page chrome. Backend tests cover replacement privacy, replay, failure, old-version
access, progress, browser envelope identity, and sanitization. The script test
gate verifies that `CapturePage.js` matches the pinned Readability source and
`scripts/capture_helpers.js` plus `scripts/safari_capture.js`; regenerate it with
`python3 scripts/build_safari_capture.py` after changing a source.

`BrowserCaptureReliabilityTests` and the backend's browser-capture regression
tests share reduced publisher and title fixtures. The test target has a Resources
phase so those fixtures travel with the test bundle; synchronized groups still
own source membership. Tests check retained paragraphs and images, safe and
idempotent chart sanitization, title consistency, and chart rendering in WebKit.
Android's reader tests verify the same static image representation, including
unsafe-payload rejection and rendering on an emulator. Run `make android-check`
and the `ArticleReaderTest` instrumentation suite when changing that allowlist.

A physical-device share-sheet check is still required before release, especially
signed-in Safari capture, offline saving, VoiceOver, and the new provisioning
profiles.

## Static charts

Supported inline SVG charts become self-contained SVG image elements during
backend sanitization. The SVG is rebuilt from a small allowlist of static shapes,
text, geometry, colors, and typography. Publisher scripts, event handlers,
external references, embedded HTML, animation, and arbitrary CSS are omitted;
complex features such as gradients, filters, and external fonts are not retained.
Chart captions and image descriptions remain available, while axis labels stay
out of narration and text-offset calculations. iOS already supports the image
representation; Android's reader allowlist now validates the same static subset.
Android needs the updated client to display these charts. No new JSON fields or
client-side permissions are required.
These embedded chart images are part of the saved HTML and work offline;
ordinary remotely hosted article images still require a network connection.

Existing immutable captures are unchanged. Re-share an affected article or use
**Replace saved text** after the updated capture code and backend are available
to recover discarded text/images and update a social-post title.


## Embedded videos

The backend preserves YouTube (including Substack's youtube-nocookie embeds)
and Vimeo players when extracting pages, accepting Safari captures, and reading
full-content feeds. It normalises exact player URLs and permissions, removes
autoplay and publisher scripts, and leaves spoken text/bookmarks unchanged.
The iOS and Android readers size players to the page, require user interaction,
and offer an external-browser link for offline, restricted, or unavailable videos.
Video media is streamed by the provider and is not included in offline saves.
Other providers, arbitrary iframes, and publisher-specific video widgets are not
supported. Android can render these in supplied article HTML; live article
fetching remains outside the current preview.

Previously cached feed articles regain players only if their retained feed HTML
has exactly the same spoken text. Existing immutable saved captures and old
offline copies cannot recover discarded markup; saving a fresh copy is required.
Safari capture retains recognised players for backend sanitisation. Frozen
released clients and the JSON payload shape remain unchanged.
