"""End-to-end tests for /auth/apple, /auth/logout and /me.

These use a client WITHOUT the get_current_user override so the real
bearer-token path runs, with Apple's JWKS endpoint mocked via respx.
"""

import base64
import time
from collections.abc import AsyncIterator

import jwt
import pytest
import respx
from cryptography.hazmat.primitives.asymmetric import rsa
from httpx import ASGITransport, AsyncClient, Response
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.auth import service
from audioreader.auth.apple import APPLE_ISSUER, AppleTokenVerifier, get_verifier
from audioreader.config import settings
from audioreader.db import get_session
from audioreader.main import create_app
from audioreader.models import AuthSession, User, UserIdentity

JWKS_URL = "https://appleid.test/auth/keys"
KID = "test-key-1"


def _b64url(value: int, length: int) -> str:
    return base64.urlsafe_b64encode(value.to_bytes(length, "big")).rstrip(b"=").decode()


@pytest.fixture(scope="module")
def apple_keys() -> tuple[rsa.RSAPrivateKey, dict]:
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    numbers = private_key.public_key().public_numbers()
    jwks = {
        "keys": [
            {
                "kty": "RSA",
                "kid": KID,
                "use": "sig",
                "alg": "RS256",
                "n": _b64url(numbers.n, 256),
                "e": _b64url(numbers.e, 3),
            }
        ]
    }
    return private_key, jwks


@pytest.fixture
def make_identity_token(apple_keys):
    private_key, _ = apple_keys

    def make(
        sub: str = "apple-subject-1",
        aud: str | None = None,
        iss: str = APPLE_ISSUER,
        email: str | None = "user@example.com",
        expires_in: int = 600,
        kid: str = KID,
    ) -> str:
        claims = {
            "sub": sub,
            "aud": aud if aud is not None else settings.apple_bundle_id,
            "iss": iss,
            "iat": int(time.time()),
            "exp": int(time.time()) + expires_in,
        }
        if email is not None:
            claims["email"] = email
        return jwt.encode(claims, private_key, algorithm="RS256", headers={"kid": kid})

    return make


@pytest.fixture
async def auth_client(session: AsyncSession, apple_keys) -> AsyncIterator[AsyncClient]:
    _, jwks = apple_keys
    app = create_app()
    app.dependency_overrides[get_session] = lambda: session
    # Fresh verifier per test: no JWKS cache bleeding between tests.
    verifier = AppleTokenVerifier(audience=settings.apple_bundle_id, jwks_url=JWKS_URL)
    app.dependency_overrides[get_verifier] = lambda: verifier
    transport = ASGITransport(app=app)
    with respx.mock:
        respx.get(JWKS_URL).mock(return_value=Response(200, json=jwks))
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


async def login(auth_client: AsyncClient, token: str) -> Response:
    return await auth_client.post("/auth/apple", json={"identity_token": token})


class TestAppleLogin:
    async def test_creates_user_identity_and_session(
        self, auth_client, make_identity_token, session
    ):
        response = await login(auth_client, make_identity_token())
        assert response.status_code == 200
        body = response.json()
        assert body["token"]
        assert body["user"]["id"]

        identity = await session.scalar(select(UserIdentity))
        assert identity.provider == "apple"
        assert identity.provider_subject == "apple-subject-1"
        stored = await session.scalar(select(AuthSession))
        # Only the hash is stored, never the raw token.
        assert stored.token_hash != body["token"]
        assert stored.token_hash == service.hash_token(body["token"])

    async def test_same_subject_reuses_user(self, auth_client, make_identity_token, session):
        first = await login(auth_client, make_identity_token(sub="mum"))
        second = await login(auth_client, make_identity_token(sub="mum"))
        assert first.json()["user"]["id"] == second.json()["user"]["id"]
        assert await session.scalar(select(func.count(User.id))) == 1

    async def test_every_new_identity_gets_a_fresh_user(
        self, auth_client, make_identity_token, session
    ):
        # The migration's placeholder must never be handed to a sign-in; it
        # exists only for the require_auth=false transition fallback.
        placeholder = User(id=service.LEGACY_USER_ID, display_name="Library owner")
        session.add(placeholder)
        await session.commit()

        response = await login(auth_client, make_identity_token(sub="mum"))
        assert response.json()["user"]["id"] != str(service.LEGACY_USER_ID)

        other = await login(auth_client, make_identity_token(sub="henry"))
        assert other.json()["user"]["id"] != response.json()["user"]["id"]

    async def test_wrong_audience_rejected(self, auth_client, make_identity_token):
        response = await login(auth_client, make_identity_token(aud="com.example.other"))
        assert response.status_code == 401

    async def test_wrong_issuer_rejected(self, auth_client, make_identity_token):
        response = await login(auth_client, make_identity_token(iss="https://evil.example"))
        assert response.status_code == 401

    async def test_expired_token_rejected(self, auth_client, make_identity_token):
        response = await login(auth_client, make_identity_token(expires_in=-60))
        assert response.status_code == 401

    async def test_unknown_kid_rejected(self, auth_client, make_identity_token):
        response = await login(auth_client, make_identity_token(kid="unknown-kid"))
        assert response.status_code == 401

    async def test_garbage_token_rejected(self, auth_client):
        response = await login(auth_client, "not-a-jwt")
        assert response.status_code == 401


class TestSessions:
    async def test_me_roundtrip(self, auth_client, make_identity_token):
        token = (await login(auth_client, make_identity_token())).json()["token"]
        response = await auth_client.get("/me", headers={"Authorization": f"Bearer {token}"})
        assert response.status_code == 200

    async def test_no_token_is_401(self, auth_client):
        response = await auth_client.get("/me")
        assert response.status_code == 401
        # Spoken-error contract: the app reads errors aloud.
        assert "spoken_response" in response.json()["detail"]

    async def test_junk_token_is_401(self, auth_client):
        response = await auth_client.get("/me", headers={"Authorization": "Bearer junk"})
        assert response.status_code == 401

    async def test_logout_revokes_token(self, auth_client, make_identity_token):
        token = (await login(auth_client, make_identity_token())).json()["token"]
        headers = {"Authorization": f"Bearer {token}"}
        assert (await auth_client.post("/auth/logout", headers=headers)).status_code == 204
        assert (await auth_client.get("/me", headers=headers)).status_code == 401

    async def test_legacy_user_is_not_reachable_without_a_token(self, auth_client, session):
        # The pre-auth placeholder row still exists in the deployed database;
        # no request may reach it except through a real session token.
        session.add(User(id=service.LEGACY_USER_ID, display_name="Library owner"))
        await session.commit()

        assert (await auth_client.get("/me")).status_code == 401
