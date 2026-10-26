# PDF imports

The private PDF beta supports importing a file from Files/document providers,
sharing a PDF file, and sharing a PDF URL from Safari or Chrome through the
existing Magpie share flow. A server-accepted PDF appears in Saved while Datalab
prepares it. Completed imports use the existing reader, offline cache, player
and immutable article progress contracts.

## Availability and saving

The server requires all of the following before accepting or submitting a PDF:

- `AUDIOREADER_PDF_IMPORT_ENABLED` is true (the default).
- `DATALAB_API_KEY` is configured on that server.
- A linked Apple/Google identity has an email in
  `AUDIOREADER_PDF_IMPORT_EMAILS`. Its default is exactly
  `hcndashwood@gmail.com`; this is not matched against editable profile data.

The allowlist is evaluated on the server on every import and again before a
queued job is submitted. Development tokens do not bypass it. Existing readable
PDFs remain accessible if importing is disabled. Saving a PDF confirms processing;
there is no separate consent step or requirement to open the app from the share
pane. Both clients explain Datalab processing alongside PDF import controls.
Account merges preserve both libraries.

This configuration enables the beta only on servers carrying the key. A local
`.env` does not configure staging or production. Deployments must use the
existing staging and manual production-promotion process in
[Backend releases](backend-releases.md); this feature does not change it.

## Browser sharing

The app sends the URL to the backend, which passes it as Datalab's `file_url`.
The phone does not download and upload the PDF first. PDF MIME hints and `.pdf`
paths bypass webpage extraction. For eligible accounts, URL-only shares can be
classified using a bounded server probe, including extensionless download URLs.
Probes check every redirect against the existing public-network rules.

Signed query parameters are preserved; browser credentials and cookies are not
sent. Links that return login pages, have expired, or cannot be fetched offer a
file-sharing fallback. Datalab fetches the URL independently, so a successful
probe does not guarantee identical later bytes or redirects. The original web
address is stored only in the private document record and owner-facing response,
not in the shared episode catalogue.

Safari's share pane completes once the server acknowledges the document job.
Android browser sharing retains the existing behaviour: confirmed links are
queued on the device and synced when Saved opens. The displayed confirmation
must distinguish that local save from a server-accepted conversion. File imports
upload in the import/share pane and retain their account-bound local copy after
an interruption. Local file retries are available in Import PDF; iOS also retries
when Saved opens. Preparing rows refresh while Saved is visible.

## Storage and processing

`PDFDocument` contains the private source URL or uploaded bytes, processing
receipt, lease and compressed provider result. Files and results are stored in
the database for this small beta, capped by an account storage allowance. Move
blobs behind an object-storage adapter before expanding volume.

A private, unsubscribed `Feed` with `source=document` holds each account's PDF
items. Existing private-feed filtering governs library, search and playback;
PDF content lives only in owned `ArticleContent` records. No PDF feed is polled
as RSS. Document fields added to episode responses are optional, preserving
released clients.

The lifespan worker claims database leases and executes short submit/poll steps.
Network work happens outside transactions. A restart resumes known provider
requests. An interrupted submission without a known provider ID becomes a
visible failure; explicit retry may charge again, so the message says so.
Expired leases, deletion and account changes prevent stale results from being
published. Provider result deletions have a durable queue that survives document
and account deletion.

Datalab balanced mode returns HTML and JSON with synthetic figure captions
disabled. Magpie sanitises HTML, removes remote images/scripts/frames, preserves
headings/tables/math, and embeds validated bounded PNG/JPEG figures for offline
reading. Unsupported figures retain a visible fallback. Speech is derived from
the same sanitised content, with table-cell separation. Structured raw results,
including the original LaTeX, are retained in the private document record.

### Equations

Datalab's `<math>` elements contain LaTeX, not presentation MathML. The PDF
adapter converts those expressions into sanitised MathML before saving reader
content. Inline and display equations, fractions, roots, scripts, matrices and
aligned rows render natively in the iOS and Android readers, including offline.
Display equations use the existing horizontally scrolling formula container.
No external scripts or additional rendering service is required.

Malformed, oversized or unsupported expressions retain escaped, labelled LaTeX
in the reader instead of disappearing or masquerading as a typeset equation.
The adapter bounds source length and nesting and recognises unsupported commands
that the converter otherwise emits literally. It does not guarantee support for
arbitrary TeX macros or perfect extraction from every PDF; the original PDF
remains the reference.

PDF narration uses a conservative structural reading for simple operators,
fractions, roots, superscripts and subscripts. It explicitly speaks grouping
boundaries rather than concatenating numerator/denominator or base/exponent.
Unrecognised structures (such as matrices and summations), and readings longer
than 80 words, say “Equation. See the equation in the reader.” This is not a
complete mathematical speech engine. Existing non-PDF article narration and
saved progress offsets are unchanged. Already prepared PDFs keep their immutable
revision; this fix applies to newly prepared imports.

Source-page navigation and block-to-speech maps from the broader design are not
part of this beta. URL imports expose the source link; uploaded originals are
available through the authenticated original endpoint and iOS's PDF preview.
Incomplete conversion and page-limit output carry a warning in both the reader
and spoken text. A saved revision is not silently reprocessed or replaced.

## API

- `GET /documents/capability`: enabled flag and effective limits. The legacy
  `consented` field mirrors `enabled` so older beta clients can import directly.
- `PUT /documents/consent`: retained for wire compatibility with the first beta;
  the stored preference no longer gates imports or worker submissions.
- `POST /documents/resolve`: `{ "url": "…" }`; bounded PDF classification.
- `POST /documents/from-url`: URL and optional title; returns 202 and an episode.
- `POST /documents/file?filename=…`: raw PDF body; returns 202 and an episode.
- `GET /documents/{id}`: current episode and document status.
- `GET /documents/{id}/original`: private uploaded bytes, when retained.
- `DELETE /documents/{id}`: delete document and queue provider cleanup.

Existing `POST /saved` and `/saved/replace` route detected PDFs into the same
pipeline while retaining the episode response shape. `POST /saved/{episode}/retry`
retries a failed PDF; ready and active documents are not resubmitted. The new
optional `document_id` and `document_status` fields let clients acknowledge
queued work without requesting text prematurely.

Inputs deduplicate within an account by exact normalised URL or verified file
hash, including retries after a lost response. Resharing does not reset progress.
There is one active conversion per account. Different signed URLs remain
separate unless their identity can be proven.

## Limits and deletion

Defaults: 25 MiB per uploaded PDF, 200 pages, one active conversion, 500 reserved
pages per rolling day, 2,000 reserved pages per calendar month, and 100 MiB stored
original/result/reader content per account. URL submissions reserve 200 pages
because the full source is not downloaded for preflight. Reservations survive
retry and document deletion, so they cannot be bypassed. Balanced base-rate
conversion is $4 per 1,000 pages at the time of implementation; the 2,000-page
cap is approximately $8 before regional surcharges. This is a page allowance,
not an invoice-level spending guarantee.

Upload validation rejects malformed/encrypted PDFs and out-of-range page counts.
URL probes reject declared oversized responses, and Datalab receives `max_pages`.
Magpie cannot guarantee a remote byte limit when a server omits or changes its
length; capped output is labelled incomplete. Provider responses and extracted
images are bounded independently.

**Dismiss from Saved** retains content for playback restoration. **Delete PDF**
removes the original, saved content and progress and queues provider cleanup.
Account deletion does the same for all owned documents. Prepared offline copies
follow the existing per-account cache lifecycle; server deletion does not claim
to erase a disconnected device immediately.

## Verification and rollout

`backend/tests/test_documents.py` covers the verified-identity gate, saving without separate consent,
private access, deduplication, quota, browser detection, unsafe redirects, worker
recovery, deletion races, provider credential isolation and HTML normalisation.
Native tests cover queued acknowledgements, file inbox isolation and signed PDF
link routing. A live smoke test submitted the public W3C dummy PDF URL to Datalab,
confirmed readable HTML/structured output, then deleted the provider result.

Apply migration `b42e87f60d19` as part of the standard backend rollout. Run the
backend gate, frozen-client compatibility, iOS build/tests on both supported
runtimes, Android checks and emulator instrumentation before release. Datalab's [privacy policy](https://www.datalab.to/terms/privacy) requires an
appropriate data-processing agreement before submitting personal data. Confirm
the account's agreement before enabling such documents beyond public test PDFs.
Physical
browser/file-provider behaviour, VoiceOver/TalkBack and long technical-document
quality need device validation before wider rollout.

### Local verification record — 26 October 2026

- `make backend-check`: 1,228 backend tests and 188 repository-script tests
  passed; frozen dependency sync, Ruff and type checks passed.
- `make backend-compatibility`: passed against the frozen released-client
  contracts, including the macOS Swift contract runner.
- `make ios-build`: passed without compiler warnings. The full iOS 27 suite
  passed; final capture acknowledgement tests passed again after receipt
  validation was tightened.
- `make ios-test-compatibility` on iOS 26.5: 700 passed, one recording-replay
  test skipped. The first attempt crashed in the simulator's audio subsystem;
  a complete rerun passed.
- `make android-check`: passed, including 294 JVM tests. Lint reports nine
  warnings in existing dependency, network-configuration and extension-use
  categories; none points to the new PDF implementation.
- Android emulator coverage: all three new PDF transport tests and all 27
  focused sharing/Saved/reader tests passed. The full API 36.1 run executed
  319 tests: 317 passed and two voice tests failed. Both failures passed on
  separate isolated reruns: playback startup in
  `VoiceConversationTest.accountChangeDuringRequestClearsConversationAndCancelsOriginalAccount`
  and transport cancellation in
  `VoiceWireTest.cancellingTypedFilingDisconnectsItsReaderAndUsesTheOriginalRequestForCancellation`.
  The full run is therefore not recorded as a clean pass. XML reports are retained
  locally under `build/pdf-import-verification/`. An earlier API 36 run was not
  sufficient for the repository's required assistant-integration coverage.
- Live Datalab checks: the public W3C PDF converted successfully by URL. A
  second check exercised local file upload, the durable worker, real Datalab
  conversion, reader content, original-file download and deletion. Both provider
  test results were deleted.

These are local checks. No staging/production deployment, app-store upload,
physical-device installation, or production credential changes were performed.

### Equation follow-up — 26 October 2026

- A live Datalab conversion of page 4 of
  [Attention Is All You Need, arXiv v7](https://arxiv.org/abs/1706.03762v7)
  returned 22 LaTeX-bearing math elements. All 22 converted into MathML without
  a source fallback. The provider result was deleted after the check.
- The attention equation is retained as a small regression fixture in
  `backend/tests/fixtures/pdf/attention-datalab.html`. The backend test verifies
  that both native reader fixtures exactly match its prepared HTML.
- `make backend-check`: 1,243 backend tests (including 15 PDF maths cases) and
  188 repository-script tests passed, along with lint, formatting and types.
  `make backend-compatibility` passed.
- iOS: 19 rendering tests passed on iOS 27 and iOS 26.5. The equation test
  checks actual MathML layout (stacked fraction, raised exponent and root),
  enlarged text and page containment with page JavaScript disabled. The iOS
  26 run also checks horizontal formula scrolling. No compiler warnings were
  reported. The separate 14-test reader suite also passed on iOS 27.
- Android: `make android-check` passed with 294 JVM tests and the same nine
  existing lint warnings. The formula container now makes span wrappers block
  elements and keyboard-focusable, allowing wide equations to scroll rather
  than be clipped.
- Android API 36.1: all 12 reader instrumentation tests passed, including
  native fraction/superscript/root layout and horizontal equation scrolling at
  enlarged text size. The unobstructed screenshot was inspected. Initial
  attempts encountered an emulator System UI stall and a stuck UI-automation
  service; restarting the emulator without wiping data cleared them. Final XML
  and screenshot are in `build/pdf-import-verification/android-maths.*`.

The equation follow-up changes local source only. It does not deploy services,
change account eligibility, or rewrite existing saved PDF revisions.
