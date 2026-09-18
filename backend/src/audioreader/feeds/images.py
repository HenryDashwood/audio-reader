"""Resolve lazy/responsive article images before extractors discard attributes."""

import re
from urllib.parse import urljoin, urlsplit


def web_image(value: str | None, base: str) -> str | None:
    if not value or not value.strip():
        return None
    try:
        absolute = urljoin(base, value.strip())
        parsed = urlsplit(absolute)
        if parsed.scheme in {"http", "https"} and parsed.hostname and not parsed.username and not parsed.password:
            return absolute
    except ValueError:
        pass
    return None


def srcset_image(value: str, base: str) -> str | None:
    candidates = []
    for match in re.finditer(r"(?:^|,\s*)(\S+)\s+(\d+(?:\.\d+)?)([wx])(?=\s*(?:,|$))", value):
        url = web_image(match[1], base)
        if url:
            candidates.append((float(match[2]), url))
    if candidates:
        return max(candidates, key=lambda item: item[0])[1]
    return web_image(value, base) if not re.search(r"[\s,]", value) else None


def normalise_images(page, base: str) -> None:
    declared = page.xpath("//base/@href")
    if declared:
        base = web_image(declared[0], base) or base
    for img in page.iter("img"):
        # The live browser uses currentSrc first. Offline HTML can only select a
        # usable declared candidate, preferring lazy sources over placeholders.
        source = next(
            (url for key in ("data-src", "data-original", "data-lazy-src") if (url := web_image(img.get(key), base))),
            None,
        )
        for key in ("data-srcset", "srcset"):
            source = source or srcset_image(img.get(key, ""), base)
        picture = next(img.iterancestors("picture"), None)
        if not source and picture is not None:
            for candidate in picture.iter("source"):
                source = source or srcset_image(candidate.get("srcset", candidate.get("data-srcset", "")), base)
        source = source or web_image(img.get("src"), base)
        if source:
            img.set("src", source)
        for key in ("srcset", "sizes", "data-srcset", "data-src", "data-original", "data-lazy-src"):
            img.attrib.pop(key, None)
