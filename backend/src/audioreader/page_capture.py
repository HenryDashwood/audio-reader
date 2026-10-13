"""Conservative page selection and social-post titles, mirrored in Safari capture."""

import re
from copy import deepcopy
from urllib.parse import urlsplit

from lxml import html as lxml_html


def _classes(node) -> set[str]:
    return set((node.get("class") or "").split())


def normalise_link_labels(page) -> None:
    """Drop accessibility annotations, preserving links labelled only for AT."""
    label_classes = {"visually-hidden", "sr-only", "screen-reader-text"}
    for link in page.iter("a"):
        labels = [node for node in link.iterdescendants() if _classes(node) & label_classes]
        visible = deepcopy(link)
        for node in list(visible.iterdescendants()):
            if _classes(node) & label_classes and node.getparent() is not None:
                node.drop_tree()
        if visible.text_content().strip():
            for node in labels:
                if node.getparent() is not None:
                    node.drop_tree()


def flattened_article(nodes, hints: list[str]) -> str | None:
    """Bound a retry to one title-identified article, unwrapping layout divs."""
    if len(nodes) != 1:
        return None
    headings = nodes[0].xpath(".//h1")
    if len(headings) != 1:
        return None
    words = re.findall(r"\w+", headings[0].text_content().lower())
    if len(words) < 3 or not any(
        sum(word in set(re.findall(r"\w+", hint.lower())) for word in words) / len(words) >= 0.75 for hint in hints
    ):
        return None
    article = deepcopy(nodes[0])
    for node in list(article.iterdescendants()):
        if not isinstance(node.tag, str):
            continue
        if (
            node.tag in {"aside", "nav", "form", "footer", "article"}
            or node.get("role") == "complementary"
            or re.search(
                r"(?:^|\s)(?:sidebar(?:[-_]\S+)?|td-(?:ss-)?main-sidebar)(?:\s|$)",
                node.get("class", "") + " " + node.get("id", ""),
                re.I,
            )
        ):
            if node.getparent() is not None:
                node.drop_tree()
    for heading in article.xpath(".//h2 | .//h3 | .//h4"):
        if not re.match(
            r"^(?:related (?:topics|(?:internet )?links|posts|articles|stories)|"
            r"(?:more|recommended|popular|recent) (?:posts|articles|stories))(?:\s|$)",
            heading.text_content().strip(),
            re.I,
        ):
            continue
        box = heading.getparent()
        while box is not None and box is not article and not box.xpath(".//a[@href] | .//p"):
            box = box.getparent()
        if box is None or box is article or box.xpath(".//h1 | .//h2 | .//h3 | .//h4")[0] is not heading:
            continue
        if not any(
            p.text_content().strip()
            and not any(a.get("href") for a in p.iterancestors("a"))
            and sum(len(a.text_content()) for a in p.iter("a")) < len(p.text_content().strip()) / 2
            for p in box.iter("p")
        ):
            box.drop_tree()
    for node in list(article.iter("div")):
        if not node.get("lang") and not node.get("dir"):
            node.drop_tag()
    return lxml_html.tostring(article, encoding="unicode")


def _excluded(node) -> bool:
    return any(
        ancestor.tag in {"aside", "nav", "form", "footer", "article"} or "prose-sans" in _classes(ancestor)
        for ancestor in [node, *node.iterancestors()]
    )


def publisher_body(page, url: str | None) -> str | None:
    """None means generic extraction; empty means a known layout is incomplete.

    These adapters select content only. Hidden-node removal runs beforehand and
    sanitization always runs afterward, just as for generic extraction.
    """
    parsed = urlsplit(url or "")
    body = lxml_html.Element("article")
    if parsed.hostname in {"canarymedia.com", "www.canarymedia.com"} and parsed.path.startswith("/articles/"):
        mains = page.xpath("//main")
        headings = page.xpath("//main//h1")
        if len(mains) != 1 or len(headings) != 1:
            return ""
        main = mains[0]
        prose = [
            n
            for n in main.iter("div")
            if "prose" in _classes(n)
            and not _excluded(n)
            and n.xpath(".//p | .//h2 | .//h3 | .//ul | .//ol | .//blockquote | .//pre | .//table")
        ]
        columns = {n.getparent() for n in prose}
        if not columns:
            return ""
        body.append(deepcopy(headings[0]))
        selected = set()
        for node in main.iter("div", "figure", "img"):
            if node.tag == "div" and node not in prose:
                continue
            ancestors = list(node.iterancestors())
            if not any(a in columns for a in ancestors) or _excluded(node) or any(a in selected for a in ancestors):
                continue
            if node.tag == "figure" and not node.xpath(".//img | .//svg"):
                continue
            selected.add(node)
            captured = deepcopy(node)
            captured.tail = None
            if node.tag == "img":
                caption = node.getparent().getnext()
                if (
                    caption is not None
                    and caption.tag == "div"
                    and not caption.xpath(".//p | .//img | .//svg | .//script | .//form")
                    and 0 < len(caption.text_content().strip()) <= 500
                ):
                    figure = lxml_html.Element("figure")
                    figure.append(captured)
                    label = lxml_html.Element("figcaption")
                    label.text = caption.text_content().strip()
                    figure.append(label)
                    captured = figure
            body.append(captured)
        if sum(len(p.text_content().strip()) for p in body.iter("p")) < 350:
            return ""
    elif parsed.hostname == "simonwillison.net" and re.fullmatch(
        r"/\d{4}/[A-Za-z]{3}/\d{1,2}/sighting-[0-9]+/", parsed.path
    ):
        entries = [n for n in page.iter("div") if {"entry", "entryPage"} <= _classes(n)]
        if len(entries) != 1:
            return ""
        contents = [n for n in entries[0].iter("div") if "beat-content" in _classes(n)]
        if len(contents) != 1:
            return ""
        for node in contents[0]:
            if node.tag == "captioned-image-gallery" or "beat-note" in _classes(node):
                body.append(deepcopy(node))
        if not body.xpath(".//img") or not any(p.text_content().strip() for p in body.iter("p")):
            return ""
    else:
        return None
    for node in body.xpath(
        ".//script | .//style | .//form | .//nav | .//aside | .//footer | .//article | "
        './/*[contains(concat(" ", normalize-space(@class), " "), " prose-sans ")]'
    ):
        node.drop_tree()
    if (
        parsed.hostname in {"canarymedia.com", "www.canarymedia.com"}
        and sum(len(p.text_content().strip()) for p in body.iter("p")) < 350
    ):
        return ""
    return lxml_html.tostring(body, encoding="unicode")


def social_post_author(url: str | None) -> str | None:
    parsed = urlsplit(url or "")
    if parsed.hostname not in {"x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"}:
        return None
    match = re.fullmatch(r"/([A-Za-z0-9_]{1,15})/status/[0-9]+/?", parsed.path)
    return match[1] if match else None


def short_illustrated_body(page) -> str | None:
    """Only called once the page's canonical identity has been checked."""
    nodes = page.xpath("//article")
    if len(nodes) != 1 or not page.xpath('//meta[@property="og:type"][@content="article"]'):
        return None
    node = deepcopy(nodes[0])
    for extra in node.xpath(".//script | .//style | .//form | .//nav | .//aside | .//footer"):
        extra.drop_tree()
    length = sum(len(p.text_content().strip()) for p in node.iter("p"))
    if 40 <= length < 350 and node.xpath(".//img"):
        return lxml_html.tostring(node, encoding="unicode")
    return None


def social_title(url: str | None, title: str, text: str, headline: str | None = None) -> str:
    """Use the same deterministic 100-character policy in Safari and the server."""
    author = social_post_author(url)
    if not author:
        return title
    if headline and headline.strip().lower() not in {"post", "thread", "home", "x", "twitter"}:
        return headline.strip()[:500]
    prefix = f"@{author}: "
    if title.startswith(prefix) and len(title) <= 100:
        return title
    quoted = re.search(r' on (?:X|Twitter):\s*["“](.*)', title, re.DOTALL)
    opening = quoted[1] if quoted else text
    opening = re.sub(r"https?://\S+", "", opening).strip()
    opening = re.split(r"\n|(?<=[.!?])\s", opening, maxsplit=1)[0]
    opening = re.sub(r"\s+", " ", opening).strip(' "“”')
    opening = re.sub(r'["”]\s*/\s*(?:X|Twitter)$', "", opening).strip(' "“”')
    if not opening:
        return f"Post by @{author}"
    limit = 100 - len(prefix)
    if len(opening) > limit:
        end = opening[: limit - 1]
        if not opening[limit - 1].isspace() and " " in end:
            end = end.rsplit(" ", 1)[0]
        opening = end.rstrip() + "…"
    return prefix + opening


def _prose_text(node) -> str:
    copy = deepcopy(node)
    for media in copy.xpath(".//script | .//style | .//svg | .//iframe"):
        media.drop_tree()
    return " ".join(copy.text_content().split())


def substantial_paragraphs(nodes) -> list[str]:
    """Evidence of prose within an already selected article, excluding sidebars."""
    paragraphs = []
    for root in nodes:
        for p in root.iter("p"):
            ancestors = [p, *p.iterancestors()]
            if any(
                a.tag in {"aside", "nav", "form", "footer"}
                # Publisher decks and recommendation cards are summaries, not body prose.
                or bool(_classes(a) & {"article-title__dek", "collections__card"})
                or re.search(
                    r"related|newsletter|comment|social|share|promo|author|footer",
                    a.get("class", "") + " " + a.get("id", ""),
                    re.I,
                )
                or re.search(
                    r"(?:^|\s)(?:sidebar(?:[-_]\S+)?|td-(?:ss-)?main-sidebar)(?:\s|$)",
                    a.get("class", "") + " " + a.get("id", ""),
                    re.I,
                )
                for a in ancestors
            ):
                continue
            text = _prose_text(p)
            linked = sum(len(a.text_content()) for a in p.iter("a"))
            if len(text) >= 80 and linked < len(text) / 2:
                paragraphs.append(text)
    return paragraphs


def missing_prose(paragraphs: list[str], html: str) -> bool:
    if not html:
        return bool(paragraphs)
    # Extraction may rewrite line breaks and paragraph boundaries, especially in poetry.
    text = re.sub(r"\s", "", _prose_text(lxml_html.fromstring(html)))
    missing = [p for p in paragraphs if re.sub(r"\s", "", p) not in text]
    return len(missing) >= 2 or any(len(p) >= 160 for p in missing)
