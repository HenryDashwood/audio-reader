# Article PDF export

The existing reader share action offers **Share link** and **Export as PDF**
when an article has a link. Articles and newsletters without a link prepare
the PDF immediately and open the native share pane. Podcast sharing keeps
using the episode link. Both clients wait for readable article text before
enabling PDF export and show preparation, retry and cancellation states.

## Backend and contract

`GET /episodes/{episode_id}/export.pdf` requires the account bearer token.
Optional `content_id` selects a particular authorized capture, just as on
`/text`. Optional `text_version` is the lowercase SHA-256 of the exact UTF-8
reader text; a mismatch returns 409 and asks the user to reopen the article.
Successful responses contain `application/pdf`, a safe UTF-8 attachment name
and `Cache-Control: private, no-store`. Busy preparation returns 503 with
`Retry-After: 3`; rendering failures return a readable 422 error.

`audioreader.reading.article` supplies the same authorized content to reading
and export. Newsletter ownership and private browser/PDF captures retain
their existing access checks. Export never changes reading progress or PDF
import usage, and needs no database migration.

`audioreader.exports` owns a semantic HTML-to-Typst adapter, the A4 template,
asset preparation and pinned Typst 0.15.0 runtime. It supports headings,
emphasis, lists, quotes, code, tables, links, fragment destinations, images
and the MathML structures covered by the fixtures. This is a readable export
of parsed content; original webpage CSS and interactive widgets are not
reproduced. Unsupported visible elements keep their text. Unavailable images
leave a labelled alternative. JPEG photographs retain JPEG compression.

Fonts and their OFL licenses are packaged under `exports/fonts`, with exact
source identifiers and SHA-256 hashes in `sources.json`. System fonts and
remote Typst packages are not needed. The vendored fonts total about 19.2 MiB;
the native compiler comes from the pinned Python wheel. Neither Chromium nor
Pandoc nor Fullbleed is required.

## Resource limits and privacy

Each API process admits one renderer and at most four waiting requests, with
a five-second queue timeout. Image fetching has a twelve-second deadline,
four concurrent downloads, 64-image and 16 MiB total limits. It reuses the
existing public-URL fetcher without forwarding account credentials. Decoding
and resizing happen in the child process. The compiler only receives local,
prepared assets and quoted source strings. HTML is limited to 8 MiB and
50,000 elements; conversion also bounds nesting and table width.

Rendering has a twenty-second wall timeout, eighteen CPU seconds, a 32 MiB
output limit and a Linux 768 MiB address-space limit. Cancellation kills and
waits for the child before deleting its temporary workspace. A private memory
cache is capped at 64 MiB per API process with ten-minute entries, pruned on
access. Cache identity includes the account, selected content, metadata and
renderer version; authorization runs before cache lookup. Increment
`EXPORT_VERSION` when changing templates, fonts or conversion behavior.

Only duration, output size and warning counts are logged. Compiler diagnostics
and article contents are not logged. The mobile clients download to temporary
files, validate the PDF and discard results for stale selections or accounts.
Shared files remain in the app's cache for up to a day and are pruned on the
next export, allowing receiving apps time to copy them. Android exposes only
the export directory through a read-granted FileProvider URI.

## Verification and release order

`make backend-check` includes network-free authorization, asset, renderer,
cache, timeout and conversion tests plus 23 synthetic article fixtures. No
real newsletter/article corpus or benchmark PDFs are committed.
`make backend-compatibility` checks frozen released clients. The wheel must
include the template, fonts and licenses, and the backend container must render
under Linux limits. Use `make ios-build`, `make ios-test`,
`make ios-test-compatibility`, `make android-check` and emulator
`make android-test` for the clients.

Ship the backend first through the normal staging/production release process,
then the clients. An older server returns a readable unavailable message to
new clients. No production promotion or store upload is part of this change.
