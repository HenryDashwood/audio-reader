"""Portable OPML, including personal feed addresses only for their owner."""

import re
from urllib.parse import urlsplit
from xml.etree.ElementTree import Element, SubElement, tostring

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.models import FEED_SOURCE_EMAIL, FEED_SOURCE_RSS, Feed, Subscription, User

# XML 1.0 permits these characters even when upstream titles are less careful.
_INVALID_XML = re.compile(r"[^\x09\x0a\x0d\x20-\ud7ff\ue000-\ufffd\U00010000-\U0010ffff]")


def _web_url(value: str) -> bool:
    try:
        parts = urlsplit(value)
        return parts.scheme in {"http", "https"} and bool(parts.hostname) and not _INVALID_XML.search(value)
    except ValueError:
        return False


async def subscriptions_opml(session: AsyncSession, user: User) -> bytes | None:
    followed = select(Subscription.feed_id).where(Subscription.user_id == user.id)
    companions = select(Feed.companion_feed_id).where(
        Feed.id.in_(followed),
        Feed.source == FEED_SOURCE_EMAIL,
        Feed.owner_user_id == user.id,
        Feed.companion_feed_id.is_not(None),
    )
    feeds = await session.scalars(
        select(Feed)
        .where(
            or_(Feed.id.in_(followed), Feed.id.in_(companions)),
            Feed.source == FEED_SOURCE_RSS,
            or_(Feed.owner_user_id.is_(None), Feed.owner_user_id == user.id),
        )
        .order_by(Feed.title, Feed.id)
    )
    root = Element("opml", version="2.0")
    SubElement(SubElement(root, "head"), "title").text = "Magpie subscriptions"
    body = SubElement(root, "body")
    seen = set()
    for feed in feeds:
        url = feed.private_fetch_url or feed.url
        if url in seen or not _web_url(url):
            continue
        seen.add(url)
        title = _INVALID_XML.sub("", feed.title)
        attrs = {"text": title, "title": title, "type": "rss", "xmlUrl": url}
        if feed.site_url and _web_url(feed.site_url):
            attrs["htmlUrl"] = _INVALID_XML.sub("", feed.site_url)
        SubElement(body, "outline", attrs)
    if not seen:
        return None
    return tostring(root, encoding="utf-8", xml_declaration=True)
