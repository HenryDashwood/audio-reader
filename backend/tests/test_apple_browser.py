"""Real HTTP handoffs with signed Apple proofs and mocked Apple endpoints."""

import time
from urllib.parse import parse_qs, urlsplit

import jwt
import pytest
import respx
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from httpx import Response
from sqlalchemy import func, select

import test_auth_api as auth_fixtures
from audioreader import secrets_store
from audioreader.auth import service
from audioreader.config import settings
from audioreader.models import AppleBrowserFlow, User, UserIdentity, utcnow
from audioreader.routers import apple_browser

# Reuse the signed-token and real-session fixtures without duplicating their setup.
JWKS_URL = auth_fixtures.JWKS_URL
KID = auth_fixtures.KID
apple_keys = auth_fixtures.apple_keys
auth_client = auth_fixtures.auth_client
google_token = auth_fixtures.google_token
make_identity_token = auth_fixtures.make_identity_token


VERIFIER = "v" * 43
SCHEME = "com.henrydashwood.magpie.dev.auth"


@pytest.fixture(autouse=True)
def browser_settings(monkeypatch):
    key = (
        ec.generate_private_key(ec.SECP256R1())
        .private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
        .decode()
    )
    for name, value in {
        "apple_services_id": "com.magpie.test.web",
        "apple_browser_redirect_uri": "https://magpie.test/auth/apple/browser/callback",
        "apple_team_id": "TEAM123456",
        "apple_key_id": "KEY1234567",
        "apple_private_key": key,
        "apple_token_encryption_key": Fernet.generate_key().decode(),
        "apple_jwks_url": JWKS_URL,
    }.items():
        monkeypatch.setattr(settings, name, value)
    monkeypatch.setattr(apple_browser, "_verifier", None)


async def begin(client, token=None, **overrides):
    body = {
        "challenge": apple_browser.proof_challenge(VERIFIER),
        "purpose": "link" if token else "login",
        "return_scheme": SCHEME,
    }
    body.update(overrides)
    return await client.post(
        "/auth/apple/browser/start", json=body, headers={"Authorization": f"Bearer {token}"} if token else {}
    )


async def finish(client, flow, token=None, verifier=VERIFIER):
    return await client.post(
        "/auth/apple/browser/complete",
        json={"state": flow["state"], "verifier": verifier},
        headers={"Authorization": f"Bearer {token}"} if token else {},
    )


def token_exchange(apple_keys, flow, sub="apple-subject-1", **overrides):
    nonce = parse_qs(urlsplit(flow["authorization_url"]).query)["nonce"][0]
    claims = {
        "sub": sub,
        "aud": settings.apple_services_id,
        "iss": "https://appleid.apple.com",
        "iat": int(time.time()),
        "exp": int(time.time()) + 300,
        "nonce": nonce,
    }
    claims.update(overrides)
    token = jwt.encode(claims, apple_keys[0], algorithm="RS256", headers={"kid": KID})
    return respx.post(settings.apple_token_url).mock(
        return_value=Response(200, json={"id_token": token, "refresh_token": "r.web"})
    )


async def callback(client, flow, **fields):
    return await client.post("/auth/apple/browser/callback", data={"state": flow["state"], **fields})


async def native_login(client, make_identity_token):
    return (await client.post("/auth/apple", json={"identity_token": make_identity_token()})).json()


async def test_browser_login_reaches_existing_ios_account(auth_client, make_identity_token, apple_keys, session):
    native = await native_login(auth_client, make_identity_token)
    flow = (await begin(auth_client)).json()
    url = urlsplit(flow["authorization_url"])
    params = parse_qs(url.query)
    assert url.hostname == "appleid.apple.com"
    assert params["client_id"] == [settings.apple_services_id]
    assert params["response_type"] == ["code"]
    assert params["response_mode"] == ["form_post"]
    assert (await finish(auth_client, flow)).json()["status"] == "pending"
    response = await callback(auth_client, flow, code="one-time-code")
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert f"{SCHEME}://apple-sign-in" in response.text
    for secret in (flow["state"], "one-time-code", VERIFIER, native["token"]):
        assert secret not in response.text
    stored = await session.get(AppleBrowserFlow, service.hash_token(flow["state"]))
    assert stored.authorization_code.startswith(secrets_store.PREFIX)
    assert secrets_store.decrypt(stored.authorization_code) == "one-time-code"
    exchange = token_exchange(apple_keys, flow)
    response = await finish(auth_client, flow)
    assert response.status_code == 200
    assert response.json()["auth"]["user"]["id"] == native["user"]["id"]
    assert response.json()["auth"]["user"]["ai_data_sharing_consented"] is False
    assert exchange.call_count == 1
    fields = parse_qs(exchange.calls[0].request.content.decode())
    assert fields["code"] == ["one-time-code"]
    assert fields["redirect_uri"] == [settings.apple_browser_redirect_uri]
    identity = await session.scalar(select(UserIdentity))
    assert identity.refresh_token_client_id == settings.apple_services_id
    assert await session.scalar(select(func.count()).select_from(User)) == 1
    assert (await finish(auth_client, flow)).status_code == 410


async def test_google_account_can_link_apple_on_android(auth_client, google_token, apple_keys, make_identity_token):
    google = (await auth_client.post("/auth/google", json={"identity_token": google_token()})).json()
    flow = (await begin(auth_client, google["token"])).json()
    await callback(auth_client, flow, code="link-code")
    token_exchange(apple_keys, flow)
    response = await finish(auth_client, flow, google["token"])
    assert response.status_code == 200
    assert response.json()["providers"] == ["apple", "google"]
    assert response.json()["auth"] is None
    assert (await native_login(auth_client, make_identity_token))["user"]["id"] == google["user"]["id"]


async def test_other_account_conflict_does_not_move_the_identity(
    auth_client, google_token, make_identity_token, apple_keys
):
    native = await native_login(auth_client, make_identity_token)
    google = (await auth_client.post("/auth/google", json={"identity_token": google_token()})).json()
    flow = (await begin(auth_client, google["token"])).json()
    await callback(auth_client, flow, code="conflict-code")
    token_exchange(apple_keys, flow)
    assert (await finish(auth_client, flow, google["token"])).status_code == 409
    assert (await native_login(auth_client, make_identity_token))["user"]["id"] == native["user"]["id"]


async def test_link_is_bound_to_exact_live_session(auth_client, make_identity_token, apple_keys):
    native = await native_login(auth_client, make_identity_token)
    other_session = await native_login(auth_client, make_identity_token)
    flow = (await begin(auth_client, native["token"])).json()
    await callback(auth_client, flow, code="code")
    exchange = token_exchange(apple_keys, flow)
    assert (await finish(auth_client, flow)).status_code == 403
    assert (await finish(auth_client, flow, other_session["token"])).status_code == 403
    await auth_client.post("/auth/logout", headers={"Authorization": f"Bearer {native['token']}"})
    assert (await finish(auth_client, flow, native["token"])).status_code == 401
    assert exchange.call_count == 0


async def test_wrong_proof_cannot_claim_or_cancel_an_attempt(auth_client, apple_keys):
    flow = (await begin(auth_client)).json()
    await callback(auth_client, flow, code="code")
    exchange = token_exchange(apple_keys, flow)
    assert (await finish(auth_client, flow, verifier="x" * 43)).status_code == 400
    assert (
        await auth_client.post("/auth/apple/browser/cancel", json={"state": flow["state"], "verifier": "x" * 43})
    ).status_code == 400
    assert exchange.call_count == 0
    assert (await finish(auth_client, flow)).status_code == 200


@pytest.mark.parametrize(
    "claims",
    [
        {"nonce": "wrong"},
        {"aud": "wrong"},
        {"aud": "com.henrydashwood.hearful"},
        {"exp": 1},
        {"iss": "https://wrong.test"},
        {"sub": ""},
    ],
)
async def test_invalid_apple_identity_cannot_create_an_account(auth_client, apple_keys, claims, session):
    flow = (await begin(auth_client)).json()
    await callback(auth_client, flow, code="code")
    token_exchange(apple_keys, flow, **claims)
    assert (await finish(auth_client, flow)).status_code == 400
    assert await session.scalar(select(func.count()).select_from(User)) == 0


async def test_duplicate_callback_cannot_replace_first_result(auth_client, apple_keys):
    flow = (await begin(auth_client)).json()
    await callback(auth_client, flow, code="first-code")
    await callback(auth_client, flow, code="second-code")
    exchange = token_exchange(apple_keys, flow)
    assert (await finish(auth_client, flow)).status_code == 200
    assert parse_qs(exchange.calls[0].request.content.decode())["code"] == ["first-code"]


async def test_provider_cancellation_creates_no_user(auth_client, session):
    flow = (await begin(auth_client)).json()
    await callback(auth_client, flow, error="user_cancelled_authorize")
    assert (await finish(auth_client, flow)).json()["status"] == "cancelled"
    assert await session.scalar(select(func.count()).select_from(User)) == 0


async def test_client_cancel_and_expiration_reject_late_callbacks(auth_client, session):
    flow = (await begin(auth_client)).json()
    assert (
        await auth_client.post("/auth/apple/browser/cancel", json={"state": flow["state"], "verifier": VERIFIER})
    ).status_code == 204
    assert (await callback(auth_client, flow, code="late-code")).status_code == 400
    flow = (await begin(auth_client)).json()
    stored = await session.get(AppleBrowserFlow, service.hash_token(flow["state"]))
    stored.expires_at = utcnow()
    await session.commit()
    assert (await finish(auth_client, flow)).status_code == 410
    assert (await callback(auth_client, flow, code="late-code")).status_code == 400
    await begin(auth_client)
    assert await session.get(AppleBrowserFlow, stored.state_hash) is None


async def test_invalid_callback_and_redirect_are_rejected(auth_client):
    flow = (await begin(auth_client)).json()
    assert (await callback(auth_client, {"state": "x" * 43}, code="code")).status_code == 400
    assert (
        await auth_client.post("/auth/apple/browser/callback", json={"state": flow["state"], "code": "code"})
    ).status_code == 400
    assert (await begin(auth_client, return_scheme="https://evil.test")).status_code == 422
    assert (await begin(auth_client, purpose="link")).status_code == 401


async def test_disabled_browser_preserves_native_apple(auth_client, make_identity_token, monkeypatch):
    monkeypatch.setattr(settings, "apple_services_id", "")
    assert (await begin(auth_client)).status_code == 503
    assert "token" in await native_login(auth_client, make_identity_token)


@pytest.mark.parametrize("revoke_on_delete", [True, False])
async def test_deleting_browser_account_revokes_with_services_id(
    auth_client, apple_keys, session, monkeypatch, revoke_on_delete
):
    monkeypatch.setattr(settings, "apple_revoke_on_account_deletion", revoke_on_delete)
    flow = (await begin(auth_client)).json()
    await callback(auth_client, flow, code="code")
    token_exchange(apple_keys, flow)
    account = (await finish(auth_client, flow)).json()["auth"]
    revoke = respx.post(settings.apple_revoke_url).mock(return_value=Response(200))
    pending = (await begin(auth_client, account["token"])).json()
    assert (
        await auth_client.delete("/me", headers={"Authorization": f"Bearer {account['token']}"})
    ).status_code == 204
    assert revoke.call_count == int(revoke_on_delete)
    if revoke_on_delete:
        assert parse_qs(revoke.calls[0].request.content.decode())["client_id"] == [settings.apple_services_id]
    assert await session.scalar(select(func.count()).select_from(UserIdentity)) == 0
    assert (await finish(auth_client, pending, account["token"])).status_code == 410
