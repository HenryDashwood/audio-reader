"""Targeting stays private, account-scoped and enforced by the backend."""

import pytest
from fastapi import HTTPException
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete, text

from audioreader import billing, feature_flags
from audioreader.admin import execute, parser
from audioreader.auth.merge import combine_accounts
from audioreader.main import create_app
from audioreader.models import FeatureFlag, User, UserFeatureFlag, UserIdentity


async def command(session, *args):
    result = await execute(session, parser().parse_args(args))
    await session.flush()
    return result


async def test_defaults_overrides_unknown_and_isolation(session, user, make_client):
    await command(session, "create", "experiment", "--description", "An experiment")
    assert not await feature_flags.enabled(session, user, "experiment")
    assert not await feature_flags.enabled(session, user, "unknown")
    with pytest.raises(HTTPException) as denied:
        await feature_flags.require_enabled(session, user, "unknown")
    assert denied.value.status_code == 403
    await command(session, "set-user", "experiment", "on", "--user-id", str(user.id))
    await feature_flags.require_enabled(session, user, "experiment")
    other = User()
    session.add(other)
    await session.commit()
    async with make_client(user) as client:
        response = await client.get("/me/features", params={"user_id": str(other.id)})
        assert response.json() == {"experiment": True}
        assert response.headers["cache-control"] == "private, no-store"
        assert (await client.get("/me")).json()["feature_flags"] == response.json()
    async with make_client(other) as client:
        assert (await client.get("/me/features")).json() == {"experiment": False}
        assert (await client.put("/me/features", json={"experiment": True})).status_code == 405
    await command(session, "set-default", "experiment", "on")
    await command(session, "set-user", "experiment", "off", "--user-id", str(user.id))
    assert not await feature_flags.enabled(session, user, "experiment")
    assert await feature_flags.enabled(session, other, "experiment")
    await command(session, "reset-user", "experiment", "--user-id", str(user.id))
    assert await feature_flags.enabled(session, user, "experiment")


async def test_feature_endpoint_requires_authentication():
    async with AsyncClient(transport=ASGITransport(app=create_app()), base_url="http://test") as client:
        assert (await client.get("/me/features")).status_code == 401


async def test_admin_email_uses_verified_identity_and_refuses_ambiguity(session, user):
    await command(session, "create", "experiment", "--description", "An experiment")
    user.email = "profile@example.test"
    with pytest.raises(ValueError, match="No account"):
        await command(session, "set-user", "experiment", "on", "--email", user.email)
    session.add(UserIdentity(user_id=user.id, provider="google", provider_subject="one", email="Linked@example.test"))
    await session.flush()
    await command(session, "set-user", "experiment", "on", "--email", "LINKED@example.test")
    assert await feature_flags.enabled(session, user, "experiment")
    other = User()
    session.add(other)
    await session.flush()
    session.add(UserIdentity(user_id=other.id, provider="apple", provider_subject="two", email="linked@example.test"))
    await session.flush()
    with pytest.raises(ValueError, match="multiple accounts"):
        await command(session, "set-user", "experiment", "off", "--email", "linked@example.test")
    assert await feature_flags.enabled(session, user, "experiment")


async def test_admin_validation_and_inspection(session, user):
    await command(session, "create", "experiment", "--description", "An experiment")
    with pytest.raises(ValueError, match="already exists"):
        await command(session, "create", "experiment", "--description", "Duplicate")
    with pytest.raises(ValueError, match="Unknown flag"):
        await command(session, "set-user", "typo", "on", "--user-id", str(user.id))
    with pytest.raises(ValueError, match="Account not found"):
        await command(session, "set-user", "experiment", "on", "--user-id", "00000000-0000-0000-0000-000000000000")
    with pytest.raises(SystemExit):
        parser().parse_args(["create", "Invalid Key", "--description", "Invalid"])
    await command(session, "set-user", "experiment", "off", "--user-id", str(user.id))
    assert await command(session, "show-user", "--user-id", str(user.id)) == {
        "user_id": str(user.id),
        "features": {"experiment": False},
        "overrides": {"experiment": False},
    }
    assert await command(session, "list") == [
        {
            "key": "experiment",
            "description": "An experiment",
            "default_enabled": False,
        }
    ]


@pytest.mark.parametrize(
    "target_value,source_value,expected",
    [(None, True, True), (True, False, False), (False, True, False), (True, True, True)],
)
async def test_account_merge_preserves_overrides_and_explicit_denials(
    session, user, target_value, source_value, expected
):
    await session.execute(text("PRAGMA foreign_keys=ON"))
    source = User()
    session.add_all([source, FeatureFlag(key="experiment", description="An experiment")])
    await session.flush()
    if target_value is not None:
        session.add(UserFeatureFlag(user_id=user.id, flag_key="experiment", enabled=target_value))
    session.add(UserFeatureFlag(user_id=source.id, flag_key="experiment", enabled=source_value))
    await session.flush()
    await combine_accounts(session, user, source)
    assert await feature_flags.enabled(session, user, "experiment") == expected
    assert await session.get(UserFeatureFlag, (source.id, "experiment")) is None


async def test_pdf_unlimited_revocation_is_immediate_and_identity_does_not_grant_it(session, user):
    user.email = "reader@example.test"
    session.add(UserIdentity(user_id=user.id, provider="google", provider_subject="reader", email=user.email))
    await command(session, "create", "pdf_unlimited", "--description", "Unlimited PDFs")
    assert not await billing.unlimited(session, user)
    await command(session, "set-user", "pdf_unlimited", "on", "--user-id", str(user.id))
    assert await billing.has_access(session, user)
    await command(session, "set-user", "pdf_unlimited", "off", "--user-id", str(user.id))
    assert not await billing.unlimited(session, user)


async def test_deleting_user_or_flag_removes_assignments(session, user):
    await session.execute(text("PRAGMA foreign_keys=ON"))
    await command(session, "create", "experiment", "--description", "An experiment")
    await command(session, "set-user", "experiment", "on", "--user-id", str(user.id))
    await session.execute(delete(FeatureFlag).where(FeatureFlag.key == "experiment"))
    assert await session.get(UserFeatureFlag, (user.id, "experiment")) is None
    await command(session, "create", "experiment", "--description", "An experiment")
    await command(session, "set-user", "experiment", "on", "--user-id", str(user.id))
    await session.execute(delete(User).where(User.id == user.id))
    assert await session.get(UserFeatureFlag, (user.id, "experiment")) is None
