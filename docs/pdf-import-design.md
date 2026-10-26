# PDF import design

Design and implementation record, 26 October 2026.

Updated interaction decision: saving a PDF is sufficient confirmation for
Datalab processing. No separate permission step is required; the current
behaviour is documented in [PDF imports](pdf-imports.md).

The private beta implementation is described in [PDF imports](pdf-imports.md).
The sections below retain the broader design, including future document-block
navigation and richer technical narration. The implemented beta uses existing
private feeds for ownership and bounded database storage rather than a new
object-storage service. It preserves reader HTML and faithful speech text;
separate semantic narration and source-page mapping remain follow-up work.

PDFs should become private items in Saved, with the same reading, listening,
offline access and progress behaviour as saved articles. Datalab handles document
conversion; Magpie owns durable processing state, uploaded originals and the
version of the content the user reads. Browser PDFs can be submitted by URL
through the existing share experience. The initial beta is available only to the
account associated with `hcndashwood@gmail.com`.

The recommended implementation is a small document ingestion path feeding the
existing article system. It needs private object storage and a database-backed
worker, but no GPU service, Redis, separate conversion deployment or general
workflow framework for the beta.

## User experience

Support both **browser → Share → Magpie** for PDF links and **Import PDF** in
Saved for local files, on iOS and Android. Browser sharing captures the URL and
sends it to Magpie's backend, which submits it to Datalab as `file_url`. There is
no requirement to download the PDF onto the phone first.

A document appears immediately with its title or filename and an honest state:
**Waiting to upload**, **Uploading**, **Preparing**, **Ready**, or **Could not
prepare**. Upload progress can be measured; conversion should use stage labels
instead of an invented percentage.

Once the server acknowledges a durable URL job or a complete file upload,
preparation continues after the app closes. Until then, preserve the pending URL
or local file against its initiating account. Failures retain that input and
offer Retry. Resharing the same URL or identical uploaded bytes finds the existing
document within the same account and does not reset reading progress.

A ready PDF opens in the existing reader with a PDF source label, section
navigation, and **View original** at the relevant page for retained files. For a
URL import without a retained original, offer **Open source PDF** instead; the
remote file may change or expire. Read and Listen use the
same item. Extracted text and reader assets download through the offline system;
downloading the original PDF is an explicit additional action. A failed-page
warning must remain visible when conversion returns incomplete content.

The PDF save preview explains that Datalab receives the PDF or its source URL
and processes the document. Tapping Save confirms the import; no separate
permission or visit to the app is required. Existing voice AI consent remains
independent. Existing ready documents remain readable if the import flag is
later disabled.

Browser PDF sharing is part of the initial beta. Detect PDFs from browser MIME
metadata when available and a bounded server content check otherwise. A `.pdf`
suffix is a hint, not the only test: download endpoints and redirects often have
no extension. Keep ordinary webpages on the current article-capture path, and
do not send PDF-viewer HTML to Readability. If a browser shares actual PDF bytes
instead of a URL, use the file-upload path.

Datalab must be able to fetch a URL without the browser's cookies. Preserve
signed query parameters when needed, keep the URL private and submit promptly.
Never forward browser credentials. A login page, expired link, inaccessible
URL, `blob:` URL or `file:` URL should offer **Save the PDF and share the file**.
Once converted, reader content remains available even if the source link expires.

## Existing foundations

`ArticleContent` already stores immutable, account-owned HTML and speech text;
`SavedArticle` selects a particular content version. `store_capture` already
handles selection and progress invalidation. These are the right destination
for a completed PDF conversion.

The OPML importer in `imports/service.py` and `main.py` demonstrates durable jobs
and database leases. Reuse its approach while keeping PDF state and concurrency
independent of subscription imports. A PDF job must not delay feed imports.

`text.py` currently turns HTML into prose, while `latex.py` and
`feeds/articles.py` provide math rendering and sanitisation. They do not provide
a complete technical-document narration policy. PDF speech should be generated
from structured blocks rather than passing the whole converted HTML through
`article_text`.

The current iOS capture inbox is deliberately URL-based, accepts at most 2 MB
of HTML, and binds pending work to an account and server. Preserve it and add a
parallel file-backed document inbox using the same account/session principles.
Extend URL capture receipts with optional PDF hints and a stable request UUID,
and let the shared intake code route detected PDFs to document conversion.
Retain old capture decoding and the existing ordinary-article behaviour.

## Processing flow

1. The client checks server capabilities. It persists
   either the shared browser URL or a protected copy of the selected file.
2. For a URL, the server validates the destination, classifies it as a PDF and
   commits an account-owned queued job using the client's request UUID. It can
   acknowledge that receipt immediately; downloading is Datalab's responsibility.
   Server probes use the existing public-network checks on every redirect, short
   timeouts and bounded response reads. A successful probe does not guarantee
   that Datalab's later fetch sees identical bytes or redirect destinations;
   verify provider fetch protections and handle source changes explicitly.
3. For a file, the server creates an upload receipt. The client streams the PDF;
   the server validates it, hashes it and stores the original durably before
   queuing conversion and acknowledging that upload is complete.
4. A worker claims a short database lease, submits the URL or file to Datalab, and
   persists the returned provider request ID. Later worker iterations poll that
   request without holding a database transaction across network calls.
5. The worker stores the result, validates it, and maps it into Magpie document
   blocks. It produces sanitised reader HTML, speech text and their mapping.
6. In one database transaction, it selects an immutable `ArticleContent`, marks
   the document ready, and records the conversion outcome. Clients then use the
   existing article reader, player and progress endpoints.

Run this lightweight worker from the API lifespan initially, with leases making
multiple API processes safe. Keep its entry point independently runnable so it
can move to a separate service if measured load warrants it. Local PDF inspection
and large-result normalisation must have bounded CPU/memory use and run outside
the API event loop.

## Datalab integration

Use the current `POST /api/v1/convert` API, authenticated with the server's
`DATALAB_API_KEY`, behind a small async HTTP adapter. Explicit submit and poll
methods make durable recovery easier than an SDK call that waits until finished.
The [quickstart](https://documentation.datalab.to/docs/welcome/quickstart)
documents multipart upload and polling by request ID.

For browser imports, send `file_url=<shared PDF URL>` to the same Convert
endpoint. Datalab downloads the document itself, as described in the
[file URL parameter](https://documentation.datalab.to/api-reference/convert-document).
Keep the API key on the backend. Both input modes feed the same polling,
normalisation, revision and Saved-item pipeline.

Proposed initial conversion settings are `mode=balanced`,
`output_format=json,html`, `add_block_ids=true`, and
`disable_image_captions=true`. Keep extracted images, omit optional paid extras,
and leave checkpoints off. These parameters and multiple output formats are
documented in the [Convert reference](https://documentation.datalab.to/api-reference/convert-document).
Explicitly disable synthetic image captions so generated descriptions cannot
silently become the author's words. Verify actual block types and identifier
relationships in the prototype before fixing the adapter schema.

Support both inline results and a signed `result_url`; the
[result contract](https://documentation.datalab.to/api-reference/convert-result-check)
also exposes page count, versions and cost information. Download external result
URLs with a separate client that carries no Datalab key, validate destinations
and redirects, and enforce response-size limits. Persist content locally rather
than using expiring provider URLs in the reader.

Use balanced mode as the starting point and compare accurate mode on difficult
fixtures. Offer an explicit higher-quality retry when useful; do not automatically
double processing charges based solely on a provider quality score. Preserve
failed-page details and treat a successful HTTP response as distinct from a
successful, complete conversion.

The [conversion guide](https://documentation.datalab.to/docs/recipes/conversion/conversion-api-overview)
says stored results expire about one day after completion and can be deleted
sooner. Retrieve results promptly and queue provider-result deletion after
durable local storage. Confirm the account's input retention, training settings
and processing region before real private-document testing; result deletion
alone does not establish those policies.

## Data model and storage

Add three small models rather than a new library or player abstraction:

| Model | Responsibility |
| --- | --- |
| `Document` | Owner, associated episode, input kind (`url` or `file`), private source URL and URL identity, title/filename, optional byte count, page count, verified hash and original object key, current import, deletion state and timestamps. |
| `DocumentImport` | One conversion attempt: state, provider request ID, configuration version, lease, next poll time, attempts, error code, actual cost and terminal outcome. |
| `DocumentRevision` | Immutable structured-block object key, assets, provider provenance and normaliser version, linked one-to-one to an `ArticleContent`. |

Use private S3-compatible object storage for original PDFs, raw conversion
results, normalised blocks and extracted images. PostgreSQL holds metadata, job
state and the existing HTML/text content. This is a new storage dependency; the
current application does not have a reusable object-storage adapter. Keep that
adapter small: put, get, delete and bounded streaming. Temporary local disk is
only a staging area, never the durable source.

Direct URL conversion does not imply that Magpie receives the original PDF.
Its original object key and source-byte hash stay null unless an exact source
copy is obtained. Store converted content and assets durably in either case.
Do not label a separate later download as the original used for conversion
without evidence that the bytes match. Original-file archiving for URL imports
can be added independently and must not block the initial browser flow.

Use opaque object keys and resolve access through current database ownership.
Do not make an account ID embedded in a key the authorisation rule, since account
merges can move ownership. Original files and assets are served through
authenticated endpoints; clients cache assets under the initiating account and
content revision. Do not embed public bucket URLs or bearer tokens in HTML.

Create a standalone `Episode` with no feed, canonical URL or web link. Add a
nullable `Episode.owner_user_id` for uploaded private items; existing rows stay
unchanged. Enforce that owner before any saved-selection fallback, and include
the ownership condition in search, voice selection, content, progress, save,
offline actions and library queries. A guessed episode ID must not let another
account create a Saved selection and thereby gain access. Do not put private
PDF bodies in shared `Episode.article_text` or `article_html` caches.

Deduplicate bytes only within an owner. Use unique constraints for upload request
IDs and live document hashes; resolve concurrent uploads transactionally. A new
parser version creates a revision of the existing document. It never silently
replaces a version being read. Reuse the existing text-version rules when the
user explicitly selects a replacement.

For URL imports, deduplicate the same conservatively normalised URL within the
owner and reuse the durable request receipt across retries. Preserve query
parameters that can change the document or grant access; exclude viewer-only
fragments from fetch identity. Treat differently signed URLs as different unless
content identity can be established. Resharing a changed URL does not silently
replace an existing revision; offer explicit reprocessing. URLs and redirect
targets never enter shared episode identities, analytics or logs.

Account merging must transfer documents, private episode ownership, revisions,
pending jobs and feature grants before deleting the old account. Resolve hash
collisions without discarding either item's progress or content history.

## Reading and listening

Normalise Datalab output into a modest, versioned Magpie representation: ordered
blocks with an ID, kind, source page, optional bounding box, content and asset
references. Start with headings, paragraphs, lists, tables, equations, figures,
captions and footnotes. Preserve unrecognised content through a visible fallback
and source-page link; never silently discard an unknown block.

| Content | Reader | Default listening |
| --- | --- | --- |
| Prose and lists | Reflowed text with semantic markup | Read faithfully in document order. |
| Headings | Accessible headings and section navigation | Read and expose as navigation points. |
| Tables | Semantic table with original page available | Announce the table and its caption; do not flatten cells into ambiguous prose. |
| Equations | Render supported math; retain source or source-page fallback | Read only supported deterministic conversions; otherwise announce the equation and its location. |
| Figures | Image and original caption | Read the original caption or identify an uncaptioned figure. |
| Footnotes and references | Available through links or sections | Keep outside the default main-text narration and make them reachable. |

Suppress repeated page headers and footers only when confidently classified.
Preserve the raw result for diagnosing mistakes. Do not add a general LLM
rewriting or summarisation pass to the first release: faithful extraction is the
primary acceptance criterion.

Generate reader HTML and speech text from the same blocks. Store an explicit map
from speech UTF-16 ranges to block IDs and source pages. Add optional document
metadata to the article-text response and a PDF-specific reader mapping path;
the existing article offset assumptions are not sufficient when visible tables
are replaced by spoken notices. Test emoji and non-BMP characters as well as
math. Never infer playback offsets by searching repeated text in the DOM.

Reuse the player timeline and text-version hashing, but bind progress and mapping
to the exact immutable revision. Extend sanitisation narrowly to preserve
generated block identifiers and safe math/table semantics. Private images need
an authenticated, locally cached resource loader on both clients. Strip scripts,
iframes, remote tracking images and unsafe link schemes from PDF content.

## Account feature flag

Use an environment kill switch plus a server-owned account grant for
`pdf_import`. At enablement, resolve the verified linked identity for
`hcndashwood@gmail.com` to its internal user ID and grant that ID. Do not trust a
client-supplied address or match mutable display email on every request. If the
verified identity does not resolve uniquely, leave access off until it does.

Expose `capabilities.pdf_import` through the existing auth response and
`GET /me`; missing capability means false on both clients. Refresh on login,
account changes and foregrounding. Include effective upload limits in the
capability response so UI copy matches server enforcement.

Enforce the flag on the server before accepting file bytes or starting/retrying
paid work. Worker submission rechecks it. Turning it off stops new submissions;
already-submitted jobs may retrieve their result and clean up provider state.
Reading and deleting existing owned PDFs continue to work. Local development
must explicitly grant its development account; a test token never bypasses the
production gate.

## API contract

These are proposed routes. All require the current account, and document lookups
return not-found for other owners.

| Route | Behaviour |
| --- | --- |
| `POST /captures/resolve` | Classify an ambiguous shared URL as PDF or webpage using a bounded, safe probe; return routing metadata without starting conversion. Known webpage captures can keep their current path. |
| `POST /documents/from-url` | Accept a request UUID, source URL, optional title; revalidate server-side and return 202 with a durable document job. |
| `POST /documents` | Accept a request UUID, filename, declared size; return a durable upload receipt. Replays return the same receipt. |
| `PUT /documents/{id}/file` | Bounded raw PDF stream; validate and store it, then return 202 and queue conversion. A replay returns the existing state and cannot overwrite completed bytes. |
| `GET /documents` | Recover pending and failed imports, with pagination. Ready items are also in Saved. |
| `GET /documents/{id}` | State, safe error code, warnings and eventual episode/content IDs. |
| `POST /documents/{id}/retry` | Idempotent explicit retry or higher-quality conversion, without a cumulative processing quota. |
| `GET /documents/{id}/original` | Authorised original download, with range support for source-page viewing. |
| `GET /documents/{id}/assets/{asset_id}` | Authorised asset belonging to an owned revision. |
| `DELETE /documents/{id}` | Immediately tombstone access and enqueue durable deletion of originals, revisions, assets and provider results. |

The shared client intake routes PDF URLs to `/documents/from-url` and ordinary
webpages to the existing `/saved` endpoint. Do not change `/saved` from its
existing episode response into a job response and break released clients. A
missing PDF capability leaves ordinary sharing available and gives a clear
unavailable message for a detected PDF.

Keep pending document rows separate from playable episodes until ready. New
clients combine them in Saved; old clients continue to see ordinary ready
article payloads. Suppress PDF-only actions on older contracts, and verify how
older readers behave with complex PDF HTML. New response fields are optional.

An interrupted upload writes to an attempt-specific temporary object. Finalise
only once under a document lock; hash and size must be verified server-side.
Replays with conflicting metadata or bytes return a conflict. Expire unfinished
receipts after 24 hours and clean orphaned upload objects.

## Recovery and deletion

Persist states for uploading, queued, submitting, processing, normalising,
ready, failed and deleting. Use lease generations so a stale worker cannot
publish content after lease loss, replacement, cancellation or deletion. The
ready transaction checks the current import and deletion state.

URL imports enter queued directly. Retrying an expired source asks for a fresh
link or file; do not repeatedly submit a known inaccessible URL. Bind a refreshed
source to the same owner and an explicit new attempt, retaining existing content.

Retry safe polls/downloads with exponential backoff, jitter and Retry-After.
Store provider request IDs immediately after submission. An ambiguous submission
timeout is special: the reviewed API does not document an idempotency key, so
automatic resubmission could charge twice. Record an uncertain outcome and
require reconciliation or an explicit retry. Database leases alone cannot
guarantee exactly-once external submission, including a crash before the provider
ID is committed. Do not treat provider caching as a billing guarantee.

Removing an item from Saved follows existing un-save semantics and retains its
content for progress restoration. A separate **Delete PDF** removes the document
and its retained content. Account deletion performs the same cleanup. Write
durable deletion tasks before database cascades erase object references; retry
storage/provider failures and reconcile orphan objects periodically. Deletion
blocks late conversion results from resurrecting content. Do not promise that
deleting a local job cancels processing already running at Datalab.

## Beta limits and cost

The private beta has no daily or monthly processing allowance. Prior usage must
not block new imports or retries. Datalab's own account limits still apply.
Resource bounds remain one active conversion per account, 25 MiB and 200 pages
per PDF, and separate storage and result-size limits.

For uploads, validate actual file structure, size, encryption and page count
before sending bytes to Datalab. Reject password-protected files initially. Use a maintained
PDF parser with strict resource and time limits; do not trust the extension,
MIME type, client hash or declared size. Bound decoded image dimensions and total
result bytes as well as the incoming PDF.

Direct URL imports cannot inherit a guaranteed local byte/page preflight without
downloading the whole file. Use a bounded PDF probe, reject declared oversized
files, set Datalab's `max_pages`, and reserve the maximum permitted conversion
cost before submission. Confirm the provider's remote-fetch byte limits and
whether exceeding `max_pages` truncates or rejects during the prototype. Label
capped output as incomplete, never as the full document; do not claim the local
25 MiB limit is enforced on an unobserved provider download. If a strict remote
byte limit is required and the provider cannot enforce it, add bounded backend
staging and pass a signed storage URL to Datalab.

Datalab's published base prices are $4 per 1,000 pages for fast/balanced and $10
for accurate. At those rates a 20-page PDF costs $0.08 or $0.20; 100 such PDFs
cost $8 or $20, before storage, retries, extras and any regional surcharge. The
pricing page lists EU processing at a 25% premium. Recheck account-specific
pricing when enabling the beta. [Datalab pricing](https://www.datalab.to/pricing)

Log document IDs, stage durations, counts, error categories, provider versions
and cost. Exclude filenames, document text, API keys and source/signed URLs from logs
and HTTP instrumentation. Monitor queue age, uncertain submissions, failures,
failed pages, cleanup backlog and cost per successfully prepared page.

## Implementation and acceptance

1. **Provider prototype.** Use the local key with synthetic/public fixtures:
   simple prose, two-column academic paper, scan, tables, equations and figures.
   Measure balanced versus accurate output and latency. Confirm JSON structure,
   block mapping, assets, partial failures, result downloads and account policy.
   Exercise direct PDF URLs, extensionless downloads, redirects, expired signed
   links, provider page caps and inaccessible browser-authenticated resources.
   Record redacted provider fixtures for offline contract tests.
2. **Backend path.** Add models/migrations, ownership checks, flag,
   storage, API routes, provider adapter, durable worker and normaliser. Suggested
   modules are `documents/service.py`, `documents/worker.py`,
   `documents/datalab.py`, `documents/normalise.py`, `documents/storage.py` and
   `routers/documents.py`. Keep provider payloads behind the adapter.
3. **Native clients.** Extend the existing browser share flow to identify PDF
   URLs and submit durable URL jobs. Add file pickers, upload inboxes, file sharing,
   pending Saved rows, document mappings and original-page actions. iOS requires
   PDF share activation, bounded file-provider copying and account-safe shared
   container access. Android needs document-provider/content URI handling,
   durable copies and account-bound background work. Neither client receives
   Datalab credentials. Preserve Dynamic Type, VoiceOver and TalkBack semantics.
4. **Private beta.** Enable only the resolved account after staging verification.
   Evaluate real documents for column order, missing text, source fidelity,
   table/math presentation and listening quality. Expand availability only after
   those results support it.

Tests must cover two-account access and guessed IDs; duplicate concurrent
uploads; interrupted upload recovery; app/account switches; worker restarts;
lease expiry; ambiguous provider submission; deletion during conversion;
account merging; historical usage not blocking saves; provider rate limits; malformed/oversized output;
failed pages; unsafe HTML/assets; revision replacement; Unicode speech mapping;
and offline reading/listening with assets. Browser coverage must include Safari
and Chrome sharing, PDFs without file extensions, misleading extensions,
redirects to blocked destinations, signed-query preservation, login pages,
source changes, repeated URL shares, URL-based account isolation and unchanged
ordinary-webpage capture.

Run `make backend-check` and `make backend-compatibility` on macOS without
changing frozen clients. For the native implementation run `make ios-build`,
`make ios-test`, `make ios-test-compatibility`, `make android-check`, and relevant
Android instrumentation. Check native share/file-provider behaviour on devices
and accessibility separately. Successful parsing is insufficient if reading,
listening, progress restoration or privacy fails.

See [PDF imports](pdf-imports.md) for the implemented contract, validation and rollout requirements.
