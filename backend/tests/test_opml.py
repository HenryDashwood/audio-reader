from pathlib import Path

import pytest

from audioreader.imports import opml

FIXTURES = Path(__file__).parent / "fixtures" / "opml"


@pytest.mark.parametrize(
    "name,count", [("antennapod-public-excerpt", 2), ("overcast-extensions", 2), ("nested-reader", 2), ("mixed", 4)]
)
def test_fixture(name, count):
    result = opml.parse((FIXTURES / f"{name}.opml").read_bytes())
    assert len(result.entries) == count
    assert all(entry.status == "ready" for entry in result.entries[:2])


def test_mixed_deduplicates_and_does_not_retain_unsafe_urls():
    result = opml.parse((FIXTURES / "mixed.opml").read_bytes())
    assert result.duplicates == 1
    assert [row.url for row in result.entries[2:]] == [None, None]
    assert "do-not-retain" not in repr(result)


def document(body):
    return f'<opml version="2.0"><body>{body}</body></opml>'


@pytest.mark.parametrize("encoding", ["utf-8-sig", "utf-16", "utf-16-be"])
def test_encoding_and_entities(encoding):
    text = document('<outline text="Café &amp; 科学" xmlUrl="https://example.org/feed?a=1&amp;b=2"/>')
    if encoding == "utf-16-be":
        raw = b"\xfe\xff" + text.encode(encoding)
    else:
        raw = text.encode(encoding)
    row = opml.parse(raw).entries[0]
    assert row.title == "Café & 科学"
    assert row.url == "https://example.org/feed?a=1&b=2"


@pytest.mark.parametrize(
    "raw",
    [
        b"",
        b"<html/>",
        b"<opml><head/></opml>",
        b"<opml><body/></opml>",
        document('<outline text="Mind & Matter" xmlUrl="https://example.org/feed"/>').encode(),
        b'<!DOCTYPE opml [<!ENTITY secret SYSTEM "file:///etc/passwd">]><opml><body/></opml>',
        b'<!DOCTYPE opml SYSTEM "https://example.org/evil.dtd"><opml><body/></opml>',
        b'<opml><body><outline xmlUrl="https://example.org"/></body><body/></opml>',
        document('<outline xmlUrl="https://example.org"/>').encode()[:-4],
    ],
)
def test_rejects_invalid_whole_document(raw):
    with pytest.raises(opml.InvalidOPML):
        opml.parse(raw)


@pytest.mark.parametrize(
    "url",
    [
        "file:///etc/passwd",
        "http://user:pass@example.org/feed",
        "http://127.0.0.1/",
        "http://[::1]/",
        "https://localhost/feed",
        "https://example.org:999/feed",
        "https://example.org/with space",
        "javascript:alert(1)",
    ],
)
def test_unsafe_addresses_are_individual_failures(url):
    result = opml.parse(document(f'<outline xmlUrl="{url}"/>').encode())
    assert result.entries[0].status == "invalid"
    assert result.entries[0].url is None


def test_limits_and_boundary():
    outline = '<outline xmlUrl="https://example.org/{i}"/>'
    assert len(opml.parse(document("".join(outline.format(i=i) for i in range(2000))).encode()).entries) == 2000
    for text in [
        document("".join(outline.format(i=i) for i in range(2001))),
        document("<outline>" * 33 + outline.format(i=1) + "</outline>" * 33),
        document('<outline text="' + "a" * 8193 + '" xmlUrl="https://example.org"/>'),
    ]:
        with pytest.raises(opml.InvalidOPML):
            opml.parse(text.encode())
    with pytest.raises(opml.InvalidOPML):
        opml.parse(b" " * (opml.MAX_BYTES + 1))


def test_unknown_extensions_are_ignored_but_nested_feeds_survive():
    result = opml.parse(
        document(
            '<outline xmlns:app="urn:app" app:read="true" xmlUrl="https://a.example/feed">'
            '<outline title="Nested" xmlUrl="https://b.example/feed"/></outline>'
        ).encode()
    )
    assert [e.title for e in result.entries] == ["a.example", "Nested"]


def test_overcast_explicitly_unfollowed_shows_are_not_imported():
    result = opml.parse(
        document(
            '<outline xmlUrl="https://example.org/old" subscribed="0"/>'
            '<outline xmlUrl="https://example.org/current" subscribed="1"/>'
        ).encode()
    )
    assert [row.url for row in result.entries] == ["https://example.org/current"]
