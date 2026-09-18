# Browser save reliability investigation

Investigated 18 September 2026 against the Safari capture bundle and backend
extraction/sanitization code. The findings below describe the original failures.
The proposed changes have now been implemented; existing immutable saves remain
unchanged until re-shared or replaced.

## Implementation

- Browser and backend adapters retain Canary's split prose, headings/lists,
  photographs, and captions, and Simon Willison's short sighting galleries.
- Generic short illustrated articles can retain their identified body directly;
  incomplete generic article extraction is rejected before storing a selection.
- Inline SVG charts are rebuilt as constrained, self-contained image elements.
  Their descriptions and captions survive, and chart labels do not enter speech.
  Reader image support handles sizing without a new API contract. Android's
  local sanitizer now validates this static image subset too.
- Browser capture keeps `currentSrc` before discarding responsive markup and
  resolves lazy/picture sources for unloaded images. The backend also normalizes
  image URLs for fetched and older browser captures.
- X/Twitter status titles use a shared 100-code-point author/opening policy;
  explicit article headings and ordinary publisher titles are preserved.
- Reduced HTML and title fixtures are shared by WebKit and backend tests. SVG
  tests cover active markup, external entities/references, complexity bounds,
  stable repeated sanitization, and rendering under a restrictive reader CSP.

The exact X post still cannot be fetched independently (HTTP 403); social-title
behavior is covered with representative metadata and shared test cases. No
production service or existing saved article was modified.

## Findings

| Example | Reproduced result | Where content is lost |
| --- | --- | --- |
| [OpenRouter article](https://mmoustafa.com/blog/so-you-want-to-use-openrouter/) | All four charts are present in Safari's captured HTML, then all four disappear after backend sanitization. | Backend HTML allowlist excludes SVG. |
| [Long X post](https://x.com/ArtemisConsort/status/2097781417476546644) | The reported title behavior is consistent with the code, but the specific page could not be independently retrieved: X returned HTTP 403. | Title selection accepts page/Readability titles up to 500 characters, with no special handling for a post whose title repeats its body. |
| [Canary Media article](https://www.canarymedia.com/articles/geothermal/dig-energy-novel-geothermal-drilling-tech) | Safari captures only the first eight of sixteen prose paragraphs and neither article image. Direct backend extraction retains all sixteen paragraphs and one article image. | Browser Readability chooses the first of two separately wrapped article sections. The backend correctly honors the supplied article envelope, so it never recovers the missing section. |
| [Simon Willison's pelican post](https://simonwillison.net/2026/Sep/12/sighting-399708714/) | Safari falls back to a URL-only save. Direct backend extraction returns the sponsor banner/date/sighting header, without the post's two prose paragraphs or either photo. | The browser's short-article gate and the server's selection of the wrong content combine into a misleading successful save. |

These are reproducible pipeline failures, rather than evidence of an image
download failure in the reader. The website snapshots were fetched for this
investigation; the user's historical saved versions were not inspected.

## Original recommendations (implemented)

### 1. Detect incomplete captures before calling them successful

This has the highest priority because Canary loses half the article silently.
Its body spans two sibling sections under `main`; the later section contains
the second image and eight further paragraphs. Both sections are present in the
source page before extraction.

Improve selection of a single story whose content is split across containers.
Compare the selected result with substantial visible prose blocks in the same
identified story, particularly blocks after its last retained paragraph. A
matching title and a long opening are not enough evidence of completeness.
Do not globally append every paragraph from `main`: related stories,
subscription prompts, and author biographies must remain excluded. A narrowly
scoped publisher adapter can provide a first fix while generic selection is
improved.

Keep the backend's existing rule that an identified Safari article is sanitized
without a second extraction. Re-extracting that envelope cannot recover missing
content and would risk signed-in browser captures. Recovery belongs before the
browser discards the original page.

Acceptance checks: both article sections, all sixteen prose paragraphs in order,
both article images, and the final paragraph survive; unrelated article cards
and newsletter prompts do not.

### 2. Support short, illustrated posts

The Safari script rejects results under 350 characters. This is a poor proxy for
whether an illustrated post is complete. Simon's source has two ordinary `img`
elements inside a `captioned-image-gallery` custom element, followed by two
short paragraphs. The image URLs are already absolute; `srcset` is not the
cause of this example.

Temporarily bypassing only the final 350-character rejection recovered both
photos and both paragraphs through browser capture and backend sanitization.
The current browser extractor can therefore already preserve this gallery;
the hard minimum is the immediate browser failure.

Allow a shorter result when there is strong article identity and a coherent
body/gallery. Preserve this custom-element behavior with a regression fixture.
Do not simply accept every short fragment: the server currently treats a sponsor
banner as successfully captured text. Add explicit checks for a short extraction
dominated by page chrome, and ensure the actual post body is selected.

Acceptance checks: both photos and both paragraphs survive without the sponsor
banner, navigation, or footer; genuinely ambiguous pages retain the existing
URL-only fallback.

### 3. Preserve static charts safely

The OpenRouter charts are inline SVG, not missing external image URLs.
Readability already keeps all four. The backend removes them through
`articles.sanitised()`, which is called both during extraction and before
storing the immutable capture. A browser-only fix therefore cannot solve this.

Add support for a constrained static SVG representation, or convert supported
SVG charts into image elements. Preserve captions and accessible descriptions.
Avoid simply enabling arbitrary SVG: scripts, event handlers, external
references, embedded HTML, and animation need deliberate handling. The same
representation must survive repeated sanitization and work in existing readers
without polluting spoken text or changing bookmark offsets.

Acceptance checks: all four charts remain visible at narrow reader widths,
captions/descriptions remain available, repeated sanitization is stable, and
active content is removed. Check URL extraction as well as Safari capture.

### 4. Give social posts concise titles

The browser selects `headline || article.title || document.title`, then slices
at 500 characters. Backend metadata titles have the same maximum. Neither path
distinguishes a real headline from a social platform's body-as-title metadata.

Introduce a shared title policy for supported social-post URLs: prefer an actual
article headline; otherwise use the author and a short opening sentence or
phrase, cut at a word boundary. An approximately 80–100 character display target
would prevent the observed wall of repeated text while keeping posts
distinguishable. Keep the full post in the body and preview, and make the
share-sheet preview agree with the stored title.

An authored semantic summary is a separate product choice; it need not be a
dependency of reliable saving. The precise X markup and resulting title still
need verification with a browser capture of the reported post.

Acceptance checks: long posts, multiline opening text, emoji, URLs, ordinary
short posts, real X article headlines, and lookalike domains; no loss of body
text and no blanket shortening of normal publisher headlines.

## Additional gap found (implemented)

Safari resolves `href` and `src` but then unconditionally removes `srcset`.
It never copies the live image's `currentSrc` first. Responsive images,
`picture` sources, or placeholders with lazy-loading attributes can therefore
lose their usable image URL. This is a separate code-level finding, not the
demonstrated cause of the two reported missing-image pages. Normalize the
browser-selected image source before removing responsive/lazy-loading markup,
with fixtures for loaded and below-the-fold images.

## Verification and rollout

The investigation executed the current bundled capture script in WKWebView on
an iPhone 17 simulator with iOS 26.5, using snapshots of the three accessible
pages. Captured article envelopes were then passed through the actual backend
`saved.extract(..., browser=True, article=True)` path. URL-only extraction was
also run against each source snapshot. The focused Safari suite passed; no
compiler warnings were reported in its output. Temporary diagnostic tests were
removed after collecting results.

Reduced, deterministic fixtures now cover these markup patterns in both WebKit
and backend tests, with structural assertions for image retention, first/last
paragraphs, ordering, and title quality. Existing hidden-content, identity,
competing-story, privacy, and replacement coverage remains intact.

After implementation, the three original page snapshots were captured again in
WKWebView and passed through backend browser-envelope extraction. Both that
route and direct URL extraction now retain all four OpenRouter charts, all
sixteen Canary paragraphs and both photographs, and both Simon Willison photos
and both paragraphs. Temporary snapshot-dependent tests were removed; permanent
tests use reduced local fixtures.

Local verification includes `make backend-check` (1,114 backend and 98 script
tests), `make backend-compatibility`, `make ios-build`, and `make ios-test`.
Android passed `make android-check` (248 JVM tests, both debug APKs, and lint)
and all eight `ArticleReaderTest` emulator tests. Chart rendering was checked
visually and with pixel/layout assertions in both readers.

The iOS 27 run passed the browser-capture regression suite, but the full runner
stalled afterward without completing. A retry on an isolated simulator also
stalled with an unresponsive simulator service. Full `make ios-test-latest`
verification therefore remains incomplete; neither run reported an assertion
failure before it was stopped.

Existing saves are immutable snapshots. Once fixes ship, affected items need
Share → Magpie again or **Replace saved text**; an app update alone will not
restore discarded content. Updated browser captures require the new app capture
bundle; Android chart display also requires the updated reader. No production
services or saved content were changed by this investigation or implementation.

## Code entry points

- `scripts/safari_capture.js`: article grouping, URL/image normalization,
  Readability selection, 350-character rejection, and title selection.
- `scripts/capture_helpers.js` and `backend/src/audioreader/page_capture.py`:
  publisher adapters, completeness checks, and social-post titles.
- `backend/src/audioreader/saved.py`: browser-envelope validation, server
  extraction, title selection, and immutable capture storage.
- `backend/src/audioreader/feeds/articles.py`: reader HTML sanitization.
- `backend/src/audioreader/feeds/graphics.py`: constrained static SVG image conversion.
- `backend/src/audioreader/feeds/images.py`: responsive/lazy image normalization.
- `android/app/src/main/java/com/henrydashwood/magpie/ui/ArticleImageSource.kt`:
  validation of self-contained chart images in the Android reader.
- `backend/src/audioreader/feeds/video.py`: existing example of preserving
  supported embedded media through server text extraction.
- `ios/HearfulTests/SafariCaptureTests.swift`: WKWebView capture regression suite.
- `backend/tests/test_saved_articles.py`: capture and replacement coverage.

Edit the Safari script source and regenerate its bundled copy with
`python3 scripts/build_safari_capture.py`; do not patch the vendored Readability
bundle directly.
