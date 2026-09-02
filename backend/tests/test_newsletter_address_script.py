"""scripts/newsletter_address.py: the operator's way to an account's address."""

from scripts.newsletter_address import address_for

from audioreader.models import User, UserIdentity
from audioreader.newsletters.service import TOKEN_WORDS

DOMAIN = "magpieinbox.com"


async def test_reports_without_minting(session, user):
    user.email = "her@example.com"
    await session.commit()

    outcome = await address_for(session, "her@example.com", DOMAIN, mint=False)

    assert outcome.found and outcome.address is None and not outcome.minted
    assert user.inbound_token is None


async def test_mints_once_and_then_reports_the_same_address(session, user):
    user.email = "her@example.com"
    await session.commit()

    first = await address_for(session, "Her@Example.com", DOMAIN, mint=True)
    second = await address_for(session, "her@example.com", DOMAIN, mint=False)

    assert first.minted and first.address is not None
    assert first.address == second.address
    local, _, domain = first.address.partition("@")
    assert domain == DOMAIN and len(local.split("-")) == TOKEN_WORDS


async def test_renewing_replaces_the_address(session, user):
    user.email = "her@example.com"
    user.inbound_token = "nwxtemygmy"
    await session.commit()

    kept = await address_for(session, "her@example.com", DOMAIN, mint=True)
    renewed = await address_for(session, "her@example.com", DOMAIN, mint=True, renew=True)

    assert kept.address == f"nwxtemygmy@{DOMAIN}"
    assert renewed.minted and renewed.address is not None and renewed.address != kept.address
    assert user.inbound_token == renewed.address.partition("@")[0]


async def test_matches_a_sign_in_identity_email(session, user):
    session.add(UserIdentity(user=user, provider="apple", provider_subject="abc", email="relay@privaterelay.test"))
    await session.commit()

    outcome = await address_for(session, "relay@privaterelay.test", DOMAIN, mint=False)

    assert outcome.found


async def test_unknown_email(session):
    session.add(User(display_name="Someone", email="someone@example.com"))
    await session.commit()

    outcome = await address_for(session, "nobody@example.com", DOMAIN, mint=True)

    assert not outcome.found


async def test_the_signup_script_finds_the_account_and_signs_it_up(session, user, respx_mock, monkeypatch):
    from scripts.newsletter_signup import run  # importable, which is what running it needs

    from audioreader.auth.service import user_for_email
    from audioreader.config import settings
    from audioreader.newsletters import service

    monkeypatch.setattr(settings, "inbound_email_domain", DOMAIN)
    monkeypatch.setattr(settings, "inbound_email_secret", "operator")
    user.email = "her@example.com"
    await session.commit()
    respx_mock.get("https://letters.test/").respond(
        content=(
            b'<html><head><title>Letters</title><link href="https://substackcdn.com/x"></head>'
            b'<body><script>"{\\"subdomain\\":\\"letters\\"}"</script></body></html>'
        ),
        content_type="text/html",
    )
    submitted = respx_mock.post("https://letters.test/api/v1/free").respond(200, json={})
    respx_mock.post("https://substack.com/api/v1/email-login").respond(200, json={})

    found = await user_for_email(session, "HER@example.com")
    assert found is not None and found.id == user.id
    outcome = await service.sign_up(session, found, "https://letters.test")

    assert outcome.status == "submitted"
    assert submitted.call_count == 1
    assert callable(run)
