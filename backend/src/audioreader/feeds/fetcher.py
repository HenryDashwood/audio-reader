import httpx


class FeedFetchError(Exception):
    """The feed URL could not be fetched."""


async def fetch_feed_bytes(url: str) -> bytes:
    try:
        async with httpx.AsyncClient(
            timeout=20, follow_redirects=True, headers={"User-Agent": "audioreader/0.1"}
        ) as client:
            response = await client.get(url)
            response.raise_for_status()
            return response.content
    except httpx.HTTPError as exc:
        raise FeedFetchError(f"could not fetch {url}: {exc}") from exc
