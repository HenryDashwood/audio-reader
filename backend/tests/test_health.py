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


async def test_support_page_is_public_and_has_contact_details():
    transport = ASGITransport(app=create_app())
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/support")
    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]
    assert "mailto:" in response.text
    assert 'href="/privacy"' in response.text


async def test_privacy_policy_names_the_real_data_flows():
    # The disclosures it would be dishonest to omit: the AI provider, the
    # hosting provider, the diagnostics service that holds what she said, Apple,
    # and how to delete an account.
    transport = ASGITransport(app=create_app())
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        body = (await client.get("/privacy")).text
    for phrase in ("OpenRouter", "Delete Account", "Railway", "Apple", "Logfire"):
        assert phrase in body, f"privacy policy no longer mentions {phrase}"


async def test_privacy_policy_covers_what_the_phone_itself_reports():
    # The app sends a record of its own for every use of the microphone,
    # including the attempts that never reach the server. Disclosing only the
    # server's record would describe the smaller half of what is collected.
    transport = ASGITransport(app=create_app())
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        body = (await client.get("/privacy")).text

    assert "MetricKit" in body, "crash diagnostics are collected but not disclosed"
    assert "microphone" in body

    # The promise the client telemetry is built to keep. If a transcript or
    # audio ever starts leaving the phone in that report, this is the line that
    # has to change first.
    assert "never your words" in body
