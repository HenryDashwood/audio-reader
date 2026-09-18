"""Bounded, non-fetching OPML parser. No XML text is interpreted as instructions."""

import ipaddress
from dataclasses import dataclass
from urllib.parse import urlsplit
from xml.parsers import expat

MAX_BYTES = 5 * 1024 * 1024
MAX_ENTRIES = 2_000
MAX_DEPTH = 32
MAX_NODES = 20_000


class InvalidOPML(ValueError):
    pass


@dataclass
class Entry:
    title: str
    host: str
    url: str | None
    status: str = "ready"
    message: str | None = None


@dataclass
class Preview:
    entries: list[Entry]
    duplicates: int
    folders: bool


def public_url(value: str) -> tuple[str, str]:
    """Validate network destinations, not whether feed contents are public."""
    if len(value) > 4_096 or any(ord(c) < 33 for c in value) or "\\" in value:
        raise ValueError("The feed address is invalid.")
    parts = urlsplit(value)
    host = parts.hostname
    if parts.scheme not in {"http", "https"} or not host or parts.port not in {None, 80, 443}:
        raise ValueError("Use a public HTTP or HTTPS feed address.")
    if (parts.username is not None or parts.password is not None) and parts.scheme != "https":
        raise ValueError("Feeds containing a password require HTTPS.")
    if host.lower() == "localhost" or host.lower().endswith((".localhost", ".local")):
        raise ValueError("Local network feeds aren't supported.")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        if not address.is_global:
            raise ValueError("Local network feeds aren't supported.")
    return value, host


def parse(raw: bytes) -> Preview:
    if not raw or len(raw) > MAX_BYTES:
        raise InvalidOPML("Choose an OPML file smaller than 5 MiB.")
    parser = expat.ParserCreate()
    entries: list[Entry] = []
    seen: set[str] = set()
    stack: list[str] = []
    nodes = duplicates = candidates = 0
    folders = False
    body_seen = False

    def forbidden(*_):
        raise InvalidOPML("This file contains an unsupported XML declaration or entity.")

    def start(name: str, attrs: dict[str, str]):
        nonlocal nodes, duplicates, candidates, folders, body_seen
        nodes += 1
        stack.append(name)
        if nodes > MAX_NODES or len(stack) > MAX_DEPTH:
            raise InvalidOPML("This OPML file is too deeply nested or contains too many items.")
        if any(len(key) > 256 or len(value) > 8_192 for key, value in attrs.items()) or len(attrs) > 64:
            raise InvalidOPML("This OPML file contains an oversized field.")
        if len(stack) == 1 and name != "opml":
            raise InvalidOPML("This isn't an OPML subscription file.")
        if stack == ["opml", "body"]:
            if body_seen:
                raise InvalidOPML("This OPML file contains more than one subscription list.")
            body_seen = True
        if name != "outline" or len(stack) < 3 or stack[:2] != ["opml", "body"]:
            return
        # Overcast's all-data export also contains shows explicitly unfollowed.
        if attrs.get("subscribed") == "0":
            return
        value = attrs.get("xmlUrl", "").strip()
        if not value:
            if attrs.get("type", "").lower() in {"rss", "atom"}:
                entries.append(
                    Entry(
                        (attrs.get("text") or attrs.get("title") or "Unnamed subscription")[:256],
                        "",
                        None,
                        "invalid",
                        "This subscription has no feed address.",
                    )
                )
            else:
                folders = True
            return
        candidates += 1
        if candidates > MAX_ENTRIES or len(entries) >= MAX_ENTRIES:
            raise InvalidOPML("Import at most 2,000 subscriptions at a time.")
        if value in seen:
            duplicates += 1
            return
        seen.add(value)
        title = (attrs.get("text") or attrs.get("title") or "").strip()[:256]
        try:
            url, host = public_url(value)
        except ValueError as exc:
            # Do not retain invalid/credential-bearing addresses, even in drafts.
            entries.append(Entry(title or "Unnamed subscription", "", None, "invalid", str(exc)))
        else:
            entries.append(Entry(title or host, host, url))

    parser.StartElementHandler = start
    parser.EndElementHandler = lambda _: stack.pop()
    parser.StartDoctypeDeclHandler = forbidden
    parser.EntityDeclHandler = forbidden
    parser.ExternalEntityRefHandler = forbidden
    try:
        parser.Parse(raw, True)
    except expat.ExpatError as exc:
        raise InvalidOPML(
            "This OPML file is incomplete or could not be read. Export it again and try that copy."
        ) from exc
    if not body_seen or not entries:
        raise InvalidOPML("No subscriptions were found in this OPML file.")
    if len(entries) > MAX_ENTRIES:
        raise InvalidOPML("Import at most 2,000 subscriptions at a time.")
    return Preview(entries, duplicates, folders)
