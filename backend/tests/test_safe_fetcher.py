import httpx
import pytest

from audioreader.feeds import fetcher
from audioreader.feeds.fetcher import FeedFetchError


@pytest.mark.parametrize(
    "address",
    [
        "127.0.0.1",
        "10.0.0.1",
        "169.254.169.254",
        "100.64.0.1",
        "192.0.2.1",
        "::1",
        "fc00::1",
        "fe80::1",
    ],
)
def test_private_and_non_public_addresses_are_rejected(address):
    with pytest.raises(FeedFetchError):
        fetcher.validate_public_addresses({address})


def test_a_public_address_is_allowed():
    fetcher.validate_public_addresses({"1.1.1.1", "2606:4700:4700::1111"})


async def test_credentials_and_non_web_ports_are_rejected():
    with pytest.raises(FeedFetchError, match="credentials"):
        await fetcher.validate_public_url("https://name:secret@example.com/feed")
    with pytest.raises(FeedFetchError, match="standard web ports"):
        await fetcher.validate_public_url("https://example.com:8443/feed")


async def test_redirect_destination_is_revalidated(respx_mock, monkeypatch):
    async def resolve(host: str, _port: int) -> set[str]:
        return {"127.0.0.1"} if host == "localhost" else {"1.1.1.1"}

    monkeypatch.setattr(fetcher, "resolve_host_addresses", resolve)
    respx_mock.get("https://public.example/start").respond(
        status_code=302, headers={"Location": "http://localhost/private"}
    )

    with pytest.raises(FeedFetchError, match="private or local"):
        await fetcher.fetch_feed("https://public.example/start")


async def test_response_size_is_bounded(respx_mock):
    respx_mock.get("https://large.example/feed").respond(content=b"x" * 101)

    with pytest.raises(FeedFetchError, match="too large"):
        await fetcher.fetch_public_bytes("https://large.example/feed", max_bytes=100)


async def test_feed_limit_accepts_a_normal_feed_larger_than_five_mebibytes(respx_mock):
    content = b"x" * (5 * 1024 * 1024 + 1)
    respx_mock.get("https://large.example/podcast.xml").respond(content=content)

    fetched, _ = await fetcher.fetch_feed("https://large.example/podcast.xml")

    assert fetched == content


async def test_a_short_upstream_rate_limit_is_retried_once(respx_mock, monkeypatch):
    monkeypatch.setattr(fetcher, "DEFAULT_RETRY_DELAY_SECONDS", 0)
    responses = [httpx.Response(429), httpx.Response(200, content=b"feed")]
    route = respx_mock.get("https://busy.example/feed").mock(side_effect=responses)

    fetched, _ = await fetcher.fetch_feed("https://busy.example/feed")

    assert fetched == b"feed"
    assert route.call_count == 2


async def test_a_long_retry_after_is_reported_without_hammering(respx_mock):
    route = respx_mock.get("https://busy.example/feed").respond(status_code=429, headers={"Retry-After": "60"})

    with pytest.raises(fetcher.FeedRateLimitedError):
        await fetcher.fetch_feed("https://busy.example/feed")

    assert route.call_count == 1


async def test_requests_identify_the_app_to_rate_limiters(respx_mock):
    route = respx_mock.get("https://ua.example/feed").respond(content=b"feed")

    await fetcher.fetch_feed("https://ua.example/feed")

    agent = route.calls[0].request.headers["user-agent"]
    assert agent == fetcher.FEED_USER_AGENT
    assert agent.startswith("Hearful/")
    # Operators deciding whether to throttle us need somewhere to look us up.
    assert "+https://" in agent
