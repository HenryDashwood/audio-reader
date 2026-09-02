"""Bounded public-internet fetching for feeds and article pages.

Every URL ultimately comes from a user or an untrusted feed. Authentication is
not a security boundary here: a free account must not turn this process into a
proxy for localhost, cloud metadata, or the hosting provider's private network.
"""

import asyncio
import ipaddress
import socket
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime
from urllib.parse import urljoin, urlsplit

import httpx

# Podcast feeds routinely include the full HTML description for hundreds of
# episodes. Latent Space's ordinary Substack feed is already about 13 MiB once
# decompressed, so 5 MiB rejected a healthy feed. This remains a hard limit on
# decompressed bytes; parser-level item and field limits provide the next
# boundary after the document is accepted.
MAX_FEED_BYTES = 32 * 1024 * 1024
MAX_ARTICLE_BYTES = 8 * 1024 * 1024
MAX_REDIRECTS = 5
ALLOWED_PORTS = {80, 443}
REDIRECT_STATUSES = {301, 302, 303, 307, 308}
MAX_ETAG_CHARS = 1_024
MAX_LAST_MODIFIED_CHARS = 256
MAX_UPSTREAM_RETRIES = 1
DEFAULT_RETRY_DELAY_SECONDS = 0.5
# Ride out a short throttle rather than surfacing it: WordPress.com and other
# shared hosts hand datacenter IPs brief 429s. Discovery's 25-second deadline
# leaves room for one such wait; anything longer is reported to the user.
MAX_RETRY_DELAY_SECONDS = 8.0
RETRYABLE_STATUSES = {429, 502, 503, 504}

# Rate limiters treat identifiable feed readers far better than anonymous
# scripts, so name the product and give site operators somewhere to reach us.
FEED_USER_AGENT = "Magpie/1.0 (+https://audio-reader-production.up.railway.app/support; feed reader)"
FEED_ACCEPT = (
    "application/rss+xml, application/atom+xml, application/feed+json, "
    "application/json;q=0.9, application/xml;q=0.8, text/xml;q=0.8, text/html;q=0.7, */*;q=0.1"
)


class FeedFetchError(Exception):
    """The requested public resource could not be fetched safely."""

    code = "site_unreachable"

    def __init__(self, message: str, *, status_code: int | None = None) -> None:
        super().__init__(message)
        self.status_code = status_code


class FeedRateLimitedError(FeedFetchError):
    """The upstream site temporarily refused a polite feed request."""

    code = "site_rate_limited"


class FeedResolutionError(FeedFetchError):
    """DNS returned no address for the hostname.

    Distinct from other fetch failures so discovery can tell "this host does
    not exist" apart from "the host refused us" and try a nearby hostname —
    Substack custom domains, for one, often exist only at www.
    """


@dataclass(frozen=True)
class FeedFetchResult:
    """A feed body, or a successful conditional response with no new body."""

    content: bytes | None
    final_url: str
    etag: str | None
    last_modified: str | None
    content_type: str | None = None
    link_headers: tuple[str, ...] = ()

    @property
    def not_modified(self) -> bool:
        return self.content is None


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
        raise FeedResolutionError("the address did not resolve")
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
        raise FeedResolutionError("the address could not be resolved") from exc


@dataclass(frozen=True)
class PostResult:
    status_code: int
    content: bytes
    final_url: str


async def post_public(
    url: str,
    *,
    data: Mapping[str, str] | None = None,
    json: Mapping[str, object] | None = None,
    headers: Mapping[str, str] | None = None,
    max_bytes: int = MAX_ARTICLE_BYTES,
    user_agent: str = FEED_USER_AGENT,
) -> PostResult:
    """One POST to a public address, with the same guard as every fetch.

    Redirects are not followed: a signup endpoint that answers with one has
    accepted the submission, and the page it points at is for a browser.
    Status codes are returned rather than raised, since a 4xx here is an
    answer ("please complete the captcha") the caller wants to read.
    """
    await validate_public_url(url)
    try:
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(20),
            follow_redirects=False,
            trust_env=False,
            headers={"User-Agent": user_agent},
        ) as client:
            async with client.stream(
                "POST", url, data=dict(data) if data else None, json=json, headers=headers
            ) as response:
                content = bytearray()
                async for chunk in response.aiter_bytes():
                    content.extend(chunk)
                    if len(content) > max_bytes:
                        raise FeedFetchError("the response is too large")
                return PostResult(response.status_code, bytes(content), str(response.url))
    except FeedFetchError:
        raise
    except httpx.HTTPError as exc:
        raise FeedFetchError(f"could not reach the address: {exc}") from exc


async def fetch_public_bytes(
    url: str,
    *,
    max_bytes: int,
    user_agent: str = FEED_USER_AGENT,
) -> tuple[bytes, str]:
    """Fetch one bounded public resource, revalidating every redirect hop."""
    result = await _fetch_public_resource(url, max_bytes=max_bytes, user_agent=user_agent)
    if result.content is None:  # Conditional requests are not used through this API.
        raise FeedFetchError("the server returned no content")
    return result.content, result.final_url


async def _fetch_public_resource(
    url: str,
    *,
    max_bytes: int,
    user_agent: str = FEED_USER_AGENT,
    request_headers: Mapping[str, str] | None = None,
    accept_not_modified: bool = False,
) -> FeedFetchResult:
    """Fetch one bounded public resource, revalidating every redirect hop."""
    current = url
    try:
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(20),
            follow_redirects=False,
            trust_env=False,
            headers={"User-Agent": user_agent},
        ) as client:
            redirect_count = 0
            retry_count = 0
            while redirect_count <= MAX_REDIRECTS:
                await validate_public_url(current)
                async with client.stream("GET", current, headers=request_headers) as response:
                    if response.status_code in REDIRECT_STATUSES:
                        location = response.headers.get("location")
                        if not location:
                            raise FeedFetchError("the server returned an empty redirect")
                        if redirect_count == MAX_REDIRECTS:
                            raise FeedFetchError("the address redirected too many times")
                        current = urljoin(str(response.url), location)
                        redirect_count += 1
                        retry_count = 0
                        continue

                    if accept_not_modified and response.status_code == 304:
                        return FeedFetchResult(
                            content=None,
                            final_url=str(response.url),
                            etag=_bounded_header(response.headers.get("etag"), MAX_ETAG_CHARS),
                            last_modified=_bounded_header(
                                response.headers.get("last-modified"), MAX_LAST_MODIFIED_CHARS
                            ),
                            content_type=response.headers.get("content-type"),
                            link_headers=tuple(response.headers.get_list("link")),
                        )

                    if response.status_code in RETRYABLE_STATUSES:
                        delay = _retry_delay_seconds(response.headers.get("retry-after"))
                        if retry_count < MAX_UPSTREAM_RETRIES and delay <= MAX_RETRY_DELAY_SECONDS:
                            retry_count += 1
                            await asyncio.sleep(delay)
                            continue
                        if response.status_code == 429:
                            raise FeedRateLimitedError(
                                "the site temporarily limited Magpie's feed requests",
                                status_code=429,
                            )
                    try:
                        response.raise_for_status()
                    except httpx.HTTPStatusError as exc:
                        raise FeedFetchError(
                            f"the site returned HTTP {response.status_code}",
                            status_code=response.status_code,
                        ) from exc
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
                    return FeedFetchResult(
                        content=bytes(content),
                        final_url=str(response.url),
                        etag=_bounded_header(response.headers.get("etag"), MAX_ETAG_CHARS),
                        last_modified=_bounded_header(response.headers.get("last-modified"), MAX_LAST_MODIFIED_CHARS),
                        content_type=response.headers.get("content-type"),
                        link_headers=tuple(response.headers.get_list("link")),
                    )
    except FeedFetchError:
        raise
    except httpx.HTTPError as exc:
        raise FeedFetchError(f"could not fetch the address: {exc}") from exc

    raise FeedFetchError("the address could not be fetched")


def _retry_delay_seconds(value: str | None) -> float:
    """A bounded-server retry hint; large delays are surfaced to the user."""

    if not value:
        return DEFAULT_RETRY_DELAY_SECONDS
    try:
        return max(0.0, float(value))
    except ValueError:
        try:
            retry_at = parsedate_to_datetime(value)
        except (TypeError, ValueError, OverflowError):
            return DEFAULT_RETRY_DELAY_SECONDS
        if retry_at.tzinfo is None:
            retry_at = retry_at.replace(tzinfo=UTC)
        return max(0.0, (retry_at - datetime.now(UTC)).total_seconds())


def _bounded_header(value: str | None, max_chars: int) -> str | None:
    """Keep untrusted cache validators useful without storing unbounded text."""
    return value[:max_chars] if value else None


async def fetch_feed(url: str) -> tuple[bytes, str]:
    result = await fetch_feed_resource(url)
    if result.content is None:
        raise FeedFetchError("the server returned no content")
    return result.content, result.final_url


async def fetch_feed_resource(url: str) -> FeedFetchResult:
    """Fetch a possible feed or homepage, retaining discovery metadata."""

    return await _fetch_public_resource(
        url,
        max_bytes=MAX_FEED_BYTES,
        request_headers={"Accept": FEED_ACCEPT},
    )


async def fetch_feed_update(url: str, *, etag: str | None = None, last_modified: str | None = None) -> FeedFetchResult:
    """Fetch a feed conditionally when validators from its last poll exist."""
    headers = {"Accept": FEED_ACCEPT}
    if etag:
        headers["If-None-Match"] = etag
    if last_modified:
        headers["If-Modified-Since"] = last_modified
    return await _fetch_public_resource(
        url,
        max_bytes=MAX_FEED_BYTES,
        request_headers=headers,
        accept_not_modified=True,
    )


async def fetch_feed_bytes(url: str) -> bytes:
    content, _ = await fetch_feed(url)
    return content
