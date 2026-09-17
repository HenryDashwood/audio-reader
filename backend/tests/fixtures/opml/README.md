# OPML fixture provenance

Tests never fetch these feed URLs. All parser tests run offline.

- `antennapod-public-excerpt.opml`: two outline records transcribed from an actual
  public AntennaPod export posted by ciwchris, November 2024:
  https://gist.github.com/ciwchris/b204fbbca6f240b0cf2e789797355e60
  The wrapper retains the exporter/version conventions; date and other entries
  were omitted. This is a small real-world excerpt, not an export we made ourselves.
- `overcast-extensions.opml`: generated, with fictitious identifiers and reserved
  domains. Models the OPML 1.0 feeds/playlists/episode extension structure shown
  in https://gist.github.com/manuzhang/cc1a0cc49638f0f2a30af2e2d06dc6d3 . It is
  not a current export captured from Overcast.
- `nested-reader.opml`: generated RSS-reader folders, Atom URL, entity escaping,
  optional attributes, and personal metadata that must not be imported.
- `mixed.opml`: generated podcasts/articles, duplicate, rejected private link,
  and missing address.
- Tests also generate large/deep documents, UTF-16/BOM variants, malformed XML,
  DTD/entity payloads, extension attributes, and boundaries in memory.

The common OPML fixtures cover the documented interchange format used by Pocket
Casts, Castro, Podcast Addict, Feedly, Inoreader, NetNewsWire, NewsBlur and Readwise
Reader. They are NOT proof of testing actual exports from every named app.
Additional current exports can be added after stripping private URLs and user
metadata; record provenance and expected contents here rather than relabelling a
synthetic file as a real export.

Specification: https://2005.opml.org/spec2.html
Documented malformed-export regression (unescaped ampersand):
https://github.com/AntennaPod/AntennaPod/issues/6884
