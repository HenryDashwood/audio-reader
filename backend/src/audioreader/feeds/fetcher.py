"""Bounded public-internet fetching for feeds and article pages.

Every URL ultimately comes from a user or an untrusted feed. Authentication is
not a security boundary here: a free account must not turn this process into a
proxy for localhost, cloud metadata, or the hosting provider's private network.
"""

import asyncio
import ipaddress
import socket
from collections.abc import Iterable
from urllib.parse import urljoin, urlsplit

import httpx

MAX_FEED_BYTES = 5 * 1024 * 1024
MAX_ARTICLE_BYTES = 8 * 1024 * 1024
MAX_REDIRECTS = 5
ALLOWED_PORTS = {80, 443}
REDIRECT_STATUSES = {301, 302, 303, 307, 308}


class FeedFetchError(Exception):
    """The requested public resource could not be fetched safely."""


async def resolve_host_addresses(host: str, port: int) -> set[str]:
    """All addresses DNS currently returns for a host.

    Kept as a small seam so tests never need real DNS. The production fetcher
    still uses the original hostname for TLS certificate and Host validation;
    deployment-level egress rules remain the final defence against the narrow
    DNS-rebinding race between this check and the connection.
    """
    loop = asyncio.get_running_loop()
    records = await loop.getaddrinfo(
        host,
        port,
        family=socket.AF_UNSPEC,
        type=socket.SOCK_STREAM,
        proto=socket.IPPROTO_TCP,
    )
    return {address for record in records if isinstance((address := record[4][0]), str)}


def validate_public_addresses(addresses: Iterable[str]) -> None:
    addresses = set(addresses)
    if not addresses:
        raise FeedFetchError("the address did not resolve")
    for address in addresses:
        try:
            parsed = ipaddress.ip_address(address)
        except ValueError as exc:
            raise FeedFetchError("the address resolved unexpectedly") from exc
        # is_global excludes private, loopback, link-local, carrier NAT,
        # multicast, documentation and reserved ranges for both IPv4 and IPv6.
        if not parsed.is_global:
            raise FeedFetchError("private or local network addresses are not allowed")


async def validate_public_url(url: str) -> None:
    try:
        parsed = urlsplit(url)
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
    except ValueError as exc:
        raise FeedFetchError("the URL is not valid") from exc
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise FeedFetchError("only public HTTP and HTTPS URLs are allowed")
    if parsed.username is not None or parsed.password is not None:
        raise FeedFetchError("URLs containing credentials are not allowed")
    if port not in ALLOWED_PORTS:
        raise FeedFetchError("only standard web ports are allowed")
    try:
        validate_public_addresses(await resolve_host_addresses(parsed.hostname, port))
    except (OSError, UnicodeError) as exc:
        raise FeedFetchError("the address could not be resolved") from exc


async def fetch_public_bytes(
    url: str,
    *,
    max_bytes: int,
    user_agent: str = "audioreader/0.1",
) -> tuple[bytes, str]:
    """Fetch one bounded public resource, revalidating every redirect hop."""
    current = url
    try:
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(20),
            follow_redirects=False,
            trust_env=False,
            headers={"User-Agent": user_agent},
        ) as client:
            for redirect_count in range(MAX_REDIRECTS + 1):
                await validate_public_url(current)
                async with client.stream("GET", current) as response:
                    if response.status_code in REDIRECT_STATUSES:
                        location = response.headers.get("location")
                        if not location:
                            raise FeedFetchError("the server returned an empty redirect")
                        if redirect_count == MAX_REDIRECTS:
                            raise FeedFetchError("the address redirected too many times")
                        current = urljoin(str(response.url), location)
                        continue

                    response.raise_for_status()
                    declared = response.headers.get("content-length")
                    if declared:
                        try:
                            if int(declared) > max_bytes:
                                raise FeedFetchError("the response is too large")
                        except ValueError:
                            pass

                    content = bytearray()
                    async for chunk in response.aiter_bytes():
                        content.extend(chunk)
                        # Count decompressed bytes, not Content-Length: a small
                        # compressed response can otherwise expand without a cap.
                        if len(content) > max_bytes:
                            raise FeedFetchError("the response is too large")
                    return bytes(content), str(response.url)
    except FeedFetchError:
        raise
    except httpx.HTTPError as exc:
        raise FeedFetchError(f"could not fetch the address: {exc}") from exc

    raise FeedFetchError("the address could not be fetched")


async def fetch_feed(url: str) -> tuple[bytes, str]:
    return await fetch_public_bytes(url, max_bytes=MAX_FEED_BYTES)


async def fetch_feed_bytes(url: str) -> bytes:
    content, _ = await fetch_feed(url)
    return content
