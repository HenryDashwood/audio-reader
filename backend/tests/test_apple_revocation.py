"""Telling Apple when an account is deleted (App Store guideline 5.1.1(v)).

Apple itself is mocked throughout: what these prove is that we send the right
shape, and — more importantly — that every way this can fail leaves deletion
working anyway.
"""

import time

import httpx
import jwt
import pytest
import respx
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from httpx import Response

from audioreader.auth.apple import APPLE_ISSUER, AppleRevoker, get_revoker
from audioreader.config import settings

TOKEN_URL = "https://appleid.test/auth/token"
REVOKE_URL = "https://appleid.test/auth/revoke"


@pytest.fixture(scope="module")
def signing_key() -> tuple[str, ec.EllipticCurvePublicKey]:
    """An ES256 key pair standing in for the .p8 Apple issues."""
    private = ec.generate_private_key(ec.SECP256R1())
    pem = private.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode()
    return pem, private.public_key()


@pytest.fixture
def revoker(signing_key) -> AppleRevoker:
    pem, _ = signing_key
    return AppleRevoker(
        client_id="com.henrydashwood.hearful",
        team_id="TEAM123456",
        key_id="KEY7890123",
        private_key=pem,
        token_url=TOKEN_URL,
        revoke_url=REVOKE_URL,
    )


class TestClientSecret:
    def test_it_verifies_against_the_public_key(self, revoker, signing_key):
        _, public = signing_key
        claims = jwt.decode(
            revoker.client_secret(),
            public,
            algorithms=["ES256"],
            audience=APPLE_ISSUER,
        )
        assert claims["iss"] == "TEAM123456"
        assert claims["sub"] == "com.henrydashwood.hearful"

    def test_the_key_id_is_in_the_header(self, revoker):
        # Apple picks which public key to check against by this alone.
        assert jwt.get_unverified_header(revoker.client_secret())["kid"] == "KEY7890123"

    def test_it_expires(self, revoker):
        claims = jwt.decode(revoker.client_secret(), options={"verify_signature": False})
        assert 0 < claims["exp"] - claims["iat"] <= 15_777_000  # Apple's six-month ceiling

    def test_it_is_minted_fresh(self, revoker):
        # Never cached: a stale secret would fail exactly when an account is
        # being deleted, which is the one moment there is no second chance.
        first = revoker.client_secret(now=int(time.time()))
        second = revoker.client_secret(now=int(time.time()) + 60)
        assert first != second


class TestExchangeCode:
    async def test_returns_the_refresh_token(self, revoker):
        with respx.mock:
            respx.post(TOKEN_URL).mock(
                return_value=Response(200, json={"refresh_token": "r.abc", "access_token": "a"})
            )
            assert await revoker.exchange_code("code-123") == "r.abc"

    async def test_sends_the_code_and_a_client_secret(self, revoker):
        with respx.mock:
            route = respx.post(TOKEN_URL).mock(return_value=Response(200, json={"refresh_token": "r.abc"}))
            await revoker.exchange_code("code-123")

        sent = dict(pair.split("=", 1) for pair in route.calls.last.request.content.decode().split("&"))
        assert sent["code"] == "code-123"
        assert sent["grant_type"] == "authorization_code"
        assert sent["client_secret"]

    async def test_an_apple_error_is_not_fatal(self, revoker):
        # Sign-in must survive it; the account simply cannot be revoked later.
        with respx.mock:
            respx.post(TOKEN_URL).mock(return_value=Response(400, json={"error": "invalid_grant"}))
            assert await revoker.exchange_code("stale-code") is None

    async def test_a_response_without_a_token_is_not_fatal(self, revoker):
        with respx.mock:
            respx.post(TOKEN_URL).mock(return_value=Response(200, json={"access_token": "a"}))
            assert await revoker.exchange_code("code-123") is None

    async def test_garbage_json_is_not_fatal(self, revoker):
        with respx.mock:
            respx.post(TOKEN_URL).mock(return_value=Response(200, content=b"<html>nope</html>"))
            assert await revoker.exchange_code("code-123") is None


class TestRevoke:
    async def test_a_successful_revocation(self, revoker):
        with respx.mock:
            respx.post(REVOKE_URL).mock(return_value=Response(200))
            assert await revoker.revoke("r.abc") is True

    async def test_it_sends_the_token_and_its_hint(self, revoker):
        with respx.mock:
            route = respx.post(REVOKE_URL).mock(return_value=Response(200))
            await revoker.revoke("r.abc")

        sent = dict(pair.split("=", 1) for pair in route.calls.last.request.content.decode().split("&"))
        assert sent["token"] == "r.abc"
        assert sent["token_type_hint"] == "refresh_token"

    async def test_an_apple_error_reports_failure_rather_than_raising(self, revoker):
        with respx.mock:
            respx.post(REVOKE_URL).mock(return_value=Response(400))
            assert await revoker.revoke("r.abc") is False

    async def test_apple_being_unreachable_reports_failure(self, revoker):
        with respx.mock:
            respx.post(REVOKE_URL).mock(side_effect=httpx.ConnectError("no route to Apple"))
            assert await revoker.revoke("r.abc") is False

    async def test_even_an_unexpected_failure_reports_rather_than_raises(self, revoker):
        # This runs inside account deletion. Anything that escapes here would
        # leave her account standing after she asked for it to be gone.
        with respx.mock:
            respx.post(REVOKE_URL).mock(side_effect=RuntimeError("something we did not foresee"))
            assert await revoker.revoke("r.abc") is False

    async def test_an_unexpected_failure_during_exchange_is_survivable(self, revoker):
        with respx.mock:
            respx.post(TOKEN_URL).mock(side_effect=RuntimeError("likewise"))
            assert await revoker.exchange_code("code-123") is None


class TestConfiguration:
    def test_no_key_means_no_revoker(self, monkeypatch):
        # The ordinary state in development, and in every other test here.
        monkeypatch.setattr(settings, "apple_private_key", "")
        monkeypatch.setattr("audioreader.auth.apple._revoker", None)
        assert get_revoker() is None

    def test_a_partial_configuration_is_treated_as_none(self, monkeypatch):
        # Half a credential is worse than none: it would fail at deletion time.
        monkeypatch.setattr(settings, "apple_team_id", "TEAM123456")
        monkeypatch.setattr(settings, "apple_key_id", "")
        monkeypatch.setattr(settings, "apple_private_key", "-----BEGIN PRIVATE KEY-----")
        monkeypatch.setattr("audioreader.auth.apple._revoker", None)
        assert get_revoker() is None

    def test_a_key_pasted_with_escaped_newlines_is_repaired(self):
        # Some hosting dashboards mangle multi-line values.
        from audioreader.config import Settings

        parsed = Settings(apple_private_key="-----BEGIN-----\\nbody\\n-----END-----")
        assert "\n" in parsed.apple_private_key
        assert "\\n" not in parsed.apple_private_key
