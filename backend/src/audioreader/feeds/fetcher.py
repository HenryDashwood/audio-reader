import httpx


class FeedFetchError(Exception):
    """The feed URL could not be fetched."""


async def fetch_feed(url: str) -> tuple[bytes, str]:
    """The content at `url`, and the URL it actually came from.

    The final URL matters: sites redirect (apex to www, http to https), and a
    page's relative feed links only resolve correctly against the address the
    document was really served from.
    """
    try:
        async with httpx.AsyncClient(
            timeout=20, follow_redirects=True, headers={"User-Agent": "audioreader/0.1"}
        ) as client:
            response = await client.get(url)
            response.raise_for_status()
            return response.content, str(response.url)
    except httpx.HTTPError as exc:
        raise FeedFetchError(f"could not fetch {url}: {exc}") from exc


async def fetch_feed_bytes(url: str) -> bytes:
    content, _ = await fetch_feed(url)
    return content
