"""Keep recognised video players without trusting publisher iframe attributes."""

import re
from urllib.parse import parse_qs, urlencode, urlsplit
from uuid import uuid4

import trafilatura
from lxml import html as lxml_html


def embed_url(value: str) -> str | None:
    try:
        url = urlsplit(value)
        if url.scheme not in {"https", "http", ""} or not url.netloc or url.username or url.password:
            return None
        if url.port not in {None, 80, 443}:
            return None
    except ValueError:
        return None
    host = (url.hostname or "").lower()
    query = parse_qs(url.query)
    if host in {"youtube.com", "www.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com"}:
        if not re.fullmatch(r"/embed/[A-Za-z0-9_-]{11}", url.path):
            return None
        params = {"playsinline": "1"}
        for key in ("start", "end"):
            value = query.get(key, [""])[0]
            if re.fullmatch(r"[0-9]{1,8}", value):
                params[key] = value
        return f"https://www.youtube-nocookie.com{url.path}?{urlencode(params)}"
    if host == "player.vimeo.com" and re.fullmatch(r"/video/[0-9]+", url.path):
        params = {"dnt": "1"}
        token = query.get("h", [""])[0]
        if re.fullmatch(r"[A-Za-z0-9]+", token):
            params["h"] = token
        return f"https://player.vimeo.com{url.path}?{urlencode(params)}"
    return None


def normalise_frames(html: str) -> str:
    if "iframe" not in html.lower():
        return html
    page = lxml_html.fragment_fromstring(html, create_parent="div")
    for frame in page.xpath(".//iframe"):
        src = embed_url(frame.get("src", ""))
        if not src:
            frame.drop_tree()
            continue
        title = frame.get("title", "").strip() or "Embedded video"
        tail = frame.tail
        frame.clear()
        frame.tail = tail
        frame.attrib.update(
            {
                "src": src,
                "title": title,
                "loading": "lazy",
                "sandbox": "allow-scripts allow-same-origin allow-presentation",
                "allow": "encrypted-media; fullscreen; picture-in-picture",
                "allowfullscreen": "",
                "referrerpolicy": "strict-origin-when-cross-origin",
            }
        )
    return lxml_html.tostring(page, encoding="unicode")[5:-6]


def extract_with_videos(source: str, *, favor_recall: bool = False) -> str:
    """Protect players in article order while trafilatura selects the prose.

    Only markers inside the selected article survive; sidebar videos are never
    appended to an unrelated extraction. Tokens are per extraction, not supplied
    by a publisher, and are removed before storing or deriving spoken text.
    """
    page = lxml_html.document_fromstring(normalise_frames(source))
    videos: dict[str, str] = {}
    for frame in page.xpath("//iframe"):
        token = f"MAGPIEVIDEO{uuid4().hex}"
        tail = frame.tail
        frame.tail = None
        videos[token] = lxml_html.tostring(frame, encoding="unicode")
        frame.tag = "p"
        frame.attrib.clear()
        frame.text = token
        frame.tail = tail
    result = (
        trafilatura.extract(
            page,
            output_format="html",
            favor_recall=favor_recall,
            include_comments=False,
            include_formatting=True,
            include_images=True,
            include_links=True,
            include_tables=True,
        )
        or ""
    )
    for token, video in videos.items():
        result = result.replace(f"<p>{token}</p>", video).replace(token, video)
    return result
