"""End-to-end tests for /auth/apple, /auth/logout and /me.

These use a client WITHOUT the get_current_user override so the real
bearer-token path runs, with Apple's JWKS endpoint mocked via respx.
"""

import base64
import time
import uuid
from collections.abc import AsyncIterator
from datetime import timedelta

import jwt
import pytest
import respx
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives.asymmetric import rsa
from httpx import ASGITransport, AsyncClient, Response
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.auth import service
from audioreader.auth.apple import (
    APPLE_ISSUER,
    AppleTokenVerifier,
    get_revoker,
    get_verifier,
)
from audioreader.config import settings
from audioreader.db import get_session
from audioreader.main import create_app
from audioreader.models import (
    AuthSession,
    Episode,
    Feed,
    PlaybackPosition,
    Subscription,
    User,
    UserIdentity,
    utcnow,
)

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
    async def test_creates_user_identity_and_session(self, auth_client, make_identity_token, session):
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

    async def test_every_new_identity_gets_a_fresh_user(self, auth_client, make_identity_token, session):
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

    async def test_account_deletion_removes_everything_of_hers(self, auth_client, make_identity_token, session):
        token = (await login(auth_client, make_identity_token())).json()["token"]
        headers = {"Authorization": f"Bearer {token}"}
        user_id = uuid.UUID((await auth_client.get("/me", headers=headers)).json()["id"])

        feed = Feed(url="https://example.com/feed.xml", title="A Show")
        session.add(feed)
        await session.flush()
        episode = Episode(feed_id=feed.id, guid="g1", title="One", audio_url="https://e/1.mp3")
        session.add(episode)
        await session.flush()
        session.add(Subscription(user_id=user_id, feed_id=feed.id))
        session.add(PlaybackPosition(user_id=user_id, episode_id=episode.id, position_seconds=42.0))
        await session.commit()

        assert (await auth_client.delete("/me", headers=headers)).status_code == 204

        assert await session.scalar(select(func.count(User.id)).where(User.id == user_id)) == 0
        for table in (UserIdentity, AuthSession, Subscription, PlaybackPosition):
            remaining = await session.scalar(select(func.count()).select_from(table).where(table.user_id == user_id))
            assert remaining == 0, f"{table.__name__} rows survived deletion"

    async def test_account_deletion_keeps_the_shared_catalog(self, auth_client, make_identity_token, session):
        # Feeds and episodes are not hers to delete: other subscribers, and any
        # future sign-in of her own, still need them.
        token = (await login(auth_client, make_identity_token())).json()["token"]
        headers = {"Authorization": f"Bearer {token}"}
        feed = Feed(url="https://example.com/feed.xml", title="A Show")
        session.add(feed)
        await session.commit()

        await auth_client.delete("/me", headers=headers)

        assert await session.scalar(select(func.count(Feed.id))) == 1

    async def test_deleted_account_token_stops_working(self, auth_client, make_identity_token, session):
        token = (await login(auth_client, make_identity_token())).json()["token"]
        headers = {"Authorization": f"Bearer {token}"}
        await auth_client.delete("/me", headers=headers)

        assert (await auth_client.get("/me", headers=headers)).status_code == 401

    async def test_signing_in_again_after_deletion_is_a_fresh_account(self, auth_client, make_identity_token, session):
        # Deletion must not blacklist her: the same Apple subject signing in
        # again is simply a new account with nothing in it.
        first = await login(auth_client, make_identity_token(sub="mum"))
        headers = {"Authorization": f"Bearer {first.json()['token']}"}
        await auth_client.delete("/me", headers=headers)

        second = await login(auth_client, make_identity_token(sub="mum"))
        assert second.status_code == 200
        assert second.json()["user"]["id"] != first.json()["user"]["id"]

    async def test_deletion_needs_a_token(self, auth_client):
        assert (await auth_client.delete("/me")).status_code == 401


class FakeRevoker:
    """Stands in for Apple. Records what it was asked to do."""

    def __init__(self, refresh_token: str | None = "r.abc", revoke_succeeds: bool = True) -> None:
        self.refresh_token = refresh_token
        self.revoke_succeeds = revoke_succeeds
        self.exchanged: list[str] = []
        self.revoked: list[str] = []

    async def exchange_code(self, authorization_code: str) -> str | None:
        self.exchanged.append(authorization_code)
        return self.refresh_token

    async def revoke(self, refresh_token: str) -> bool:
        self.revoked.append(refresh_token)
        return self.revoke_succeeds


@pytest.fixture
def revoker():
    return FakeRevoker()


@pytest.fixture
async def revoking_client(session: AsyncSession, apple_keys, revoker) -> AsyncIterator[AsyncClient]:
    """Like auth_client, but with Apple revocation configured."""
    _, jwks = apple_keys
    app = create_app()
    app.dependency_overrides[get_session] = lambda: session
    verifier = AppleTokenVerifier(audience=settings.apple_bundle_id, jwks_url=JWKS_URL)
    app.dependency_overrides[get_verifier] = lambda: verifier
    app.dependency_overrides[get_revoker] = lambda: revoker
    transport = ASGITransport(app=app)
    with respx.mock:
        respx.get(JWKS_URL).mock(return_value=Response(200, json=jwks))
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client


class TestAppleRevocation:
    async def test_the_authorization_code_is_exchanged_at_sign_in(self, revoking_client, make_identity_token, revoker):
        await revoking_client.post(
            "/auth/apple",
            json={"identity_token": make_identity_token(), "authorization_code": "code-123"},
        )
        assert revoker.exchanged == ["code-123"]

    async def test_the_refresh_token_is_not_stored_in_the_clear(
        self, revoking_client, make_identity_token, session, monkeypatch
    ):
        monkeypatch.setattr(settings, "apple_token_encryption_key", Fernet.generate_key().decode())
        await revoking_client.post(
            "/auth/apple",
            json={"identity_token": make_identity_token(), "authorization_code": "code-123"},
        )

        identity = await session.scalar(select(UserIdentity))
        assert identity.refresh_token != "r.abc"
        assert "r.abc" not in identity.refresh_token

    async def test_deleting_revokes_with_apple_first(self, revoking_client, make_identity_token, revoker):
        token = (
            await revoking_client.post(
                "/auth/apple",
                json={"identity_token": make_identity_token(), "authorization_code": "code-123"},
            )
        ).json()["token"]

        await revoking_client.delete("/me", headers={"Authorization": f"Bearer {token}"})

        assert revoker.revoked == ["r.abc"]

    async def test_deletion_succeeds_even_when_apple_refuses(
        self, revoking_client, make_identity_token, revoker, session
    ):
        # Her data goes either way. An un-revoked grant is a loose end, not
        # a reason to keep the account alive.
        revoker.revoke_succeeds = False
        token = (
            await revoking_client.post(
                "/auth/apple",
                json={"identity_token": make_identity_token(), "authorization_code": "code-123"},
            )
        ).json()["token"]

        response = await revoking_client.delete("/me", headers={"Authorization": f"Bearer {token}"})

        assert response.status_code == 204
        assert await session.scalar(select(func.count(User.id))) == 0

    async def test_signing_in_without_a_code_still_works(self, revoking_client, make_identity_token, revoker):
        # An older build of the app, which does not send one.
        response = await revoking_client.post("/auth/apple", json={"identity_token": make_identity_token()})

        assert response.status_code == 200
        assert revoker.exchanged == []

    async def test_a_failed_exchange_does_not_fail_the_sign_in(self, revoking_client, make_identity_token, revoker):
        revoker.refresh_token = None
        response = await revoking_client.post(
            "/auth/apple",
            json={"identity_token": make_identity_token(), "authorization_code": "stale"},
        )
        assert response.status_code == 200

    async def test_deleting_an_account_with_no_token_still_works(
        self, revoking_client, make_identity_token, revoker, session
    ):
        # Signed in before the app began sending codes: nothing to revoke.
        revoker.refresh_token = None
        token = (await revoking_client.post("/auth/apple", json={"identity_token": make_identity_token()})).json()[
            "token"
        ]

        response = await revoking_client.delete("/me", headers={"Authorization": f"Bearer {token}"})

        assert response.status_code == 204
        assert revoker.revoked == []

    async def test_a_later_sign_in_without_a_code_keeps_the_stored_token(
        self, revoking_client, make_identity_token, revoker
    ):
        # Losing a usable token in exchange for nothing would be worse than
        # keeping a slightly older one, which revokes just as well.
        await revoking_client.post(
            "/auth/apple",
            json={"identity_token": make_identity_token(sub="mum"), "authorization_code": "c1"},
        )
        revoker.refresh_token = None
        token = (
            await revoking_client.post("/auth/apple", json={"identity_token": make_identity_token(sub="mum")})
        ).json()["token"]

        await revoking_client.delete("/me", headers={"Authorization": f"Bearer {token}"})

        assert revoker.revoked == ["r.abc"]

    async def test_an_unconfigured_deployment_simply_skips_it(self, auth_client, make_identity_token, session):
        # The default everywhere without an Apple key: deletion still works.
        token = (
            await auth_client.post(
                "/auth/apple",
                json={"identity_token": make_identity_token(), "authorization_code": "code-123"},
            )
        ).json()["token"]

        response = await auth_client.delete("/me", headers={"Authorization": f"Bearer {token}"})

        assert response.status_code == 204
        assert await session.scalar(select(func.count(User.id))) == 0

    async def test_an_idle_session_expires(self, auth_client, make_identity_token, session):
        token = (await login(auth_client, make_identity_token())).json()["token"]
        headers = {"Authorization": f"Bearer {token}"}

        stored = await session.get(AuthSession, service.hash_token(token))
        stored.last_used_at = utcnow() - timedelta(days=settings.session_idle_timeout_days + 1)
        await session.commit()

        assert (await auth_client.get("/me", headers=headers)).status_code == 401

    async def test_an_expired_session_is_marked_revoked(self, auth_client, make_identity_token, session):
        token = (await login(auth_client, make_identity_token())).json()["token"]
        stored = await session.get(AuthSession, service.hash_token(token))
        stored.last_used_at = utcnow() - timedelta(days=settings.session_idle_timeout_days + 1)
        await session.commit()

        await auth_client.get("/me", headers={"Authorization": f"Bearer {token}"})

        await session.refresh(stored)
        assert stored.revoked_at is not None

    async def test_use_keeps_a_session_alive(self, auth_client, make_identity_token, session):
        token = (await login(auth_client, make_identity_token())).json()["token"]
        headers = {"Authorization": f"Bearer {token}"}

        # Just inside the window, and using it pushes the clock forward.
        stored = await session.get(AuthSession, service.hash_token(token))
        stored.last_used_at = utcnow() - timedelta(days=settings.session_idle_timeout_days - 1)
        await session.commit()

        assert (await auth_client.get("/me", headers=headers)).status_code == 200
        await session.refresh(stored)
        assert utcnow() - service._as_aware(stored.last_used_at) < timedelta(minutes=1)

    async def test_a_never_used_session_expires_from_its_creation(self, auth_client, make_identity_token, session):
        token = (await login(auth_client, make_identity_token())).json()["token"]
        stored = await session.get(AuthSession, service.hash_token(token))
        stored.last_used_at = None
        stored.created_at = utcnow() - timedelta(days=settings.session_idle_timeout_days + 1)
        await session.commit()

        response = await auth_client.get("/me", headers={"Authorization": f"Bearer {token}"})
        assert response.status_code == 401

    async def test_expiry_can_be_disabled(self, auth_client, make_identity_token, session, monkeypatch):
        monkeypatch.setattr(settings, "session_idle_timeout_days", 0)
        token = (await login(auth_client, make_identity_token())).json()["token"]
        stored = await session.get(AuthSession, service.hash_token(token))
        stored.last_used_at = utcnow() - timedelta(days=3650)
        await session.commit()

        response = await auth_client.get("/me", headers={"Authorization": f"Bearer {token}"})
        assert response.status_code == 200

    async def test_legacy_user_is_not_reachable_without_a_token(self, auth_client, session):
        # The pre-auth placeholder row still exists in the deployed database;
        # no request may reach it except through a real session token.
        session.add(User(id=service.LEGACY_USER_ID, display_name="Library owner"))
        await session.commit()

        assert (await auth_client.get("/me")).status_code == 401
