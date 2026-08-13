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
