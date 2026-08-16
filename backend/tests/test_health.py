"""The platform's healthcheck target."""

from httpx import ASGITransport, AsyncClient

from audioreader.main import create_app


async def test_health_is_ok():
    transport = ASGITransport(app=create_app())
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


async def test_health_needs_no_token_and_no_database():
    # No get_session override and no Authorization header: if either were
    # required, a deploy could never go healthy.
    transport = ASGITransport(app=create_app())
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/health")
    assert response.status_code == 200


async def test_privacy_policy_is_public():
    # App Store Connect and TestFlight both need a link that works without a
    # login and keeps working.
    transport = ASGITransport(app=create_app())
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/privacy")
    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]


async def test_privacy_policy_names_the_real_data_flows():
    # The disclosures it would be dishonest to omit: the AI provider, the
    # hosting provider, the diagnostics service that holds what she said, Apple,
    # and how to delete an account.
    transport = ASGITransport(app=create_app())
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        body = (await client.get("/privacy")).text
    for phrase in ("OpenRouter", "Delete Account", "Railway", "Apple", "Logfire"):
        assert phrase in body, f"privacy policy no longer mentions {phrase}"
