from datetime import timedelta
from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException
from sqlalchemy import select

from audioreader import billing
from audioreader.config import settings
from audioreader.documents import service
from audioreader.models import PDFDocument, PDFPageUsage, UserIdentity, utcnow
from test_documents import pdf


@pytest.fixture
async def paid(session, user, monkeypatch):
    monkeypatch.setattr(settings, "billing_enabled", True)
    monkeypatch.setattr(settings, "revenuecat_api_key", "secret-test")
    monkeypatch.setattr(settings, "datalab_api_key", "test")
    monkeypatch.setattr(settings, "pdf_import_enabled", True)
    now = utcnow()
    subscriber = {
        "entitlements": {
            "magpie_plus": {
                "product_identifier": "magpie_plus_monthly",
                "expires_date": (now + timedelta(days=20)).isoformat(),
            }
        },
        "subscriptions": {
            "magpie_plus_monthly": {
                "store": "app_store",
                "is_sandbox": False,
                "purchase_date": (now - timedelta(days=10)).isoformat(),
                "expires_date": (now + timedelta(days=20)).isoformat(),
            }
        },
    }
    monkeypatch.setattr(billing, "fetch_subscriber", AsyncMock(return_value=subscriber))
    return subscriber


async def test_purchase_sync_requires_verified_entitlement(client, paid, session, user):
    response = await client.post("/billing/sync", json={"active": True})
    assert response.status_code == 200
    assert response.json()["remaining_pages"] == 500
    paid["entitlements"] = {}
    assert not (await client.post("/billing/sync")).json()["active"]
    assert (await client.post("/documents/file", content=pdf())).status_code == 403


async def test_owner_unlimited_even_with_billing_disabled(client, session, user, monkeypatch):
    monkeypatch.setattr(settings, "billing_enabled", False)
    session.add(
        UserIdentity(user_id=user.id, provider="google", provider_subject="owner", email="hcndashwood@gmail.com")
    )
    await session.commit()
    status = (await client.get("/billing/status")).json()
    assert status["unlimited"] and status["remaining_pages"] is None
    assert not status["available"]


async def test_profile_email_cannot_bypass_allowance(client, user, paid):
    user.email = "hcndashwood@gmail.com"
    assert not (await client.get("/billing/status")).json()["unlimited"]


async def test_reservations_deduplicate_and_deletion_does_not_refund(client, session, user, paid):
    first = await client.post("/documents/file", content=pdf())
    assert first.status_code == 202
    second = await client.post("/documents/file", content=pdf())
    assert first.json()["document_id"] == second.json()["document_id"]
    assert (await client.get("/billing/status")).json()["used_pages"] == 1
    await client.delete(f"/documents/{first.json()['document_id']}")
    assert (await client.get("/billing/status")).json()["used_pages"] == 1
    assert len(list(await session.scalars(select(PDFPageUsage)))) == 1


async def test_allowance_reset_and_over_limit(session, user, paid):
    await billing.reserve(session, user, "one", 499)
    await billing.reserve(session, user, "one", 499)
    with pytest.raises(HTTPException, match="499|1 pages left") as error:
        await billing.reserve(session, user, "two", 2)
    assert error.value.status_code == 409
    await billing.reserve(session, user, "two", 1)
    usage = await session.get_one(PDFPageUsage, "one")
    usage.created_at = utcnow() - timedelta(days=40)
    assert (await billing.status(session, user))["remaining_pages"] == 499


async def test_refund_and_sandbox_fail_closed(client, paid, monkeypatch):
    paid["subscriptions"]["magpie_plus_monthly"]["refunded_at"] = utcnow().isoformat()
    assert not (await client.post("/billing/sync")).json()["active"]
    paid["subscriptions"]["magpie_plus_monthly"]["refunded_at"] = None
    paid["subscriptions"]["magpie_plus_monthly"]["is_sandbox"] = True
    monkeypatch.setattr(settings, "environment", "production")
    assert not (await client.post("/billing/sync")).json()["active"]


async def test_expired_and_wrong_product_do_not_grant_access(client, paid):
    paid["entitlements"]["magpie_plus"]["expires_date"] = (utcnow() - timedelta(seconds=1)).isoformat()
    assert not (await client.post("/billing/sync")).json()["active"]
    paid["entitlements"]["magpie_plus"]["product_identifier"] = "unrelated"
    assert not (await client.post("/billing/sync")).json()["active"]


async def test_webhook_auth_and_duplicates(client, paid, monkeypatch):
    await client.get("/billing/status")
    monkeypatch.setattr(settings, "revenuecat_webhook_secret", "Bearer secret-test")
    body = {"event": {"app_user_id": (await client.get("/billing/status")).json()["customer_id"]}}
    assert (await client.post("/billing/webhook", json=body)).status_code == 401
    paid["entitlements"] = {}
    for _ in range(2):
        assert (
            await client.post("/billing/webhook", json=body, headers={"Authorization": "Bearer secret-test"})
        ).status_code == 200
    assert not (await client.get("/billing/status")).json()["active"]


@pytest.mark.parametrize("gap_seconds", [0, 30])
async def test_early_renewal_preserves_current_allowance_until_new_period(
    client, session, user, paid, monkeypatch, gap_seconds
):
    now = utcnow()
    current_end = now + timedelta(seconds=60)
    next_start = current_end + timedelta(seconds=gap_seconds)
    monkeypatch.setattr(billing, "utcnow", lambda: now)
    monkeypatch.setattr(settings, "revenuecat_webhook_secret", "Bearer renewal-test")
    product = paid["subscriptions"]["magpie_plus_monthly"]
    entitlement = paid["entitlements"]["magpie_plus"]
    product["expires_date"] = entitlement["expires_date"] = current_end.isoformat()
    await billing.reserve(session, user, "current-period-document", 123)
    await session.commit()
    initial = (await client.get("/billing/status")).json()
    assert initial["active"] and initial["remaining_pages"] == 377

    # Apple's sandbox can publish the next period before its purchase_date.
    product["purchase_date"] = next_start.isoformat()
    product["expires_date"] = entitlement["expires_date"] = (next_start + timedelta(minutes=5)).isoformat()
    for _ in range(2):
        webhook = await client.post(
            "/billing/webhook",
            json={"event": {"app_user_id": initial["customer_id"]}},
            headers={"Authorization": "Bearer renewal-test"},
        )
        assert webhook.status_code == 200
        restored = (await client.post("/billing/sync")).json()
        assert restored["active"] and restored["remaining_pages"] == 377
        assert restored["period_end"] == initial["period_end"]

    if gap_seconds:
        monkeypatch.setattr(billing, "utcnow", lambda: current_end + timedelta(seconds=1))
        gap = (await client.get("/billing/status")).json()
        assert not gap["active"] and gap["remaining_pages"] == 0

    monkeypatch.setattr(billing, "utcnow", lambda: next_start + timedelta(seconds=1))
    renewed = (await client.get("/billing/status")).json()
    assert renewed["active"] and renewed["remaining_pages"] == 500
    assert renewed["period_end"] != initial["period_end"]


async def test_future_purchase_cannot_grant_initial_access(client, paid, monkeypatch):
    start = utcnow() + timedelta(minutes=1)
    paid["subscriptions"]["magpie_plus_monthly"]["purchase_date"] = start.isoformat()
    status = (await client.post("/billing/sync")).json()
    assert not status["active"] and status["remaining_pages"] == 0
    monkeypatch.setattr(billing, "utcnow", lambda: start + timedelta(seconds=1))
    assert (await client.get("/billing/status")).json()["active"]


@pytest.mark.parametrize("invalid", ["refund", "sandbox", "missing_entitlement", "expired_entitlement"])
async def test_early_renewal_cannot_preserve_revoked_access(client, paid, monkeypatch, invalid):
    assert (await client.post("/billing/sync")).json()["active"]
    product = paid["subscriptions"]["magpie_plus_monthly"]
    product["purchase_date"] = (utcnow() + timedelta(minutes=1)).isoformat()
    if invalid == "refund":
        product["refunded_at"] = utcnow().isoformat()
    elif invalid == "sandbox":
        monkeypatch.setattr(settings, "environment", "production")
        product["is_sandbox"] = True
    elif invalid == "expired_entitlement":
        paid["entitlements"]["magpie_plus"]["expires_date"] = (utcnow() - timedelta(seconds=1)).isoformat()
    else:
        paid["entitlements"] = {}
    assert not (await client.post("/billing/sync")).json()["active"]


async def test_paid_url_counts_and_stores_exact_bytes(client, session, paid, monkeypatch):
    raw = pdf()
    monkeypatch.setattr(service, "download_pdf", AsyncMock(return_value=raw))
    reply = await client.post("/documents/from-url", json={"url": "https://papers.example/paper.pdf"})
    assert reply.status_code == 202
    doc = await session.get_one(PDFDocument, reply.json()["document_id"])
    await session.refresh(doc, ["original"])
    assert doc.original == raw and doc.page_count == 1
    assert (await client.get("/billing/status")).json()["remaining_pages"] == 499


async def test_provider_outage_cannot_grant_new_access(client, paid, monkeypatch):
    monkeypatch.setattr(billing, "fetch_subscriber", AsyncMock(side_effect=HTTPException(503, "Unavailable")))
    assert (await client.post("/documents/file", content=pdf())).status_code == 503


async def test_renewal_uses_new_period_and_does_not_roll_over(session, user, paid):
    await billing.reserve(session, user, "previous", 500)
    usage = await session.get_one(PDFPageUsage, "previous")
    usage.created_at = utcnow() - timedelta(days=31)
    product = paid["subscriptions"]["magpie_plus_monthly"]
    product["purchase_date"] = (utcnow() - timedelta(hours=1)).isoformat()
    product["expires_date"] = (utcnow() + timedelta(days=30)).isoformat()
    paid["entitlements"]["magpie_plus"]["expires_date"] = product["expires_date"]
    status = await billing.status(session, user, refresh=True)
    assert status["remaining_pages"] == 500


async def test_merge_preserves_store_identity_and_consumed_pages(session, user, paid):
    from audioreader.auth.merge import combine_accounts
    from audioreader.models import User

    await billing.reserve(session, user, "original-document", 400)
    customer_id = (await billing.status(session, user))["customer_id"]
    target = User(display_name="Merged")
    session.add(target)
    await session.flush()
    await combine_accounts(session, target, user)
    await session.commit()
    status = await billing.status(session, target)
    assert status["customer_id"] == customer_id
    assert status["remaining_pages"] == 100


async def test_deleting_account_erases_local_billing_state(client, session, user, paid):
    await billing.reserve(session, user, "to-delete", 50)
    await session.commit()
    assert (await client.delete("/me")).status_code == 204
    from audioreader.models import BillingCustomer

    assert await session.scalar(select(BillingCustomer.id)) is None
    assert await session.scalar(select(PDFPageUsage.document_id)) is None


async def test_expiry_does_not_cancel_already_reserved_conversion(client, session, user, paid, monkeypatch):
    from sqlalchemy.ext.asyncio import async_sessionmaker

    from audioreader.documents import datalab, worker
    from audioreader.models import BillingCustomer

    raw = pdf()
    monkeypatch.setattr(service, "download_pdf", AsyncMock(return_value=raw))
    reply = await client.post("/documents/from-url", json={"url": "https://papers.example/expiring.pdf"})
    assert reply.status_code == 202
    customer = await session.scalar(select(BillingCustomer))
    customer.access_until = utcnow() - timedelta(seconds=1)
    await session.commit()
    submit = AsyncMock(return_value="provider-id")
    monkeypatch.setattr(datalab, "submit", submit)
    assert await worker.step(async_sessionmaker(session.bind, expire_on_commit=False))
    submit.assert_awaited_once_with(None, raw)


async def test_definite_provider_failure_refunds_once_and_retry_reserves_again(
    client, session, user, paid, monkeypatch
):
    from sqlalchemy.ext.asyncio import async_sessionmaker

    from audioreader.documents import datalab, worker

    reply = await client.post("/documents/file", content=pdf())
    doc = await session.get_one(PDFDocument, reply.json()["document_id"])
    doc.status = "processing"
    doc.request_id = "failed-provider"
    await session.commit()
    monkeypatch.setattr(datalab, "poll", AsyncMock(return_value={"status": "failed", "success": False}))
    assert await worker.step(async_sessionmaker(session.bind, expire_on_commit=False))
    await session.refresh(doc)
    usage = await session.get_one(PDFPageUsage, doc.id)
    await session.refresh(usage)
    assert usage.state == "released"
    assert (await billing.status(session, user))["remaining_pages"] == 500
    await service.retry(session, user, doc)
    assert (await billing.status(session, user))["remaining_pages"] == 499


async def test_grace_period_preserves_access_without_resetting_pages(client, paid):
    product = paid["subscriptions"]["magpie_plus_monthly"]
    product["expires_date"] = (utcnow() - timedelta(minutes=1)).isoformat()
    product["grace_period_expires_date"] = (utcnow() + timedelta(days=1)).isoformat()
    paid["entitlements"]["magpie_plus"]["expires_date"] = product["expires_date"]
    assert (await client.post("/billing/sync")).json()["active"]
    assert (await client.post("/documents/file", content=pdf())).status_code == 202
    assert (await client.get("/billing/status")).json()["remaining_pages"] == 499


async def test_recent_cache_is_refreshed_at_renewal_instead_of_rejecting_subscriber(session, user, paid):
    from audioreader.models import BillingCustomer

    await billing.status(session, user)
    customer = await session.scalar(select(BillingCustomer))
    customer.access_until = utcnow() - timedelta(seconds=1)
    customer.checked_at = utcnow()
    await session.commit()
    assert await billing.has_access(session, user)
    fetch = billing.fetch_subscriber
    assert isinstance(fetch, AsyncMock)
    assert fetch.await_count == 2


async def test_purchases_unavailable_when_pdf_service_is_off(client, paid, monkeypatch):
    monkeypatch.setattr(settings, "pdf_import_enabled", False)
    response = await client.get("/billing/status")
    assert response.json()["active"]  # Existing purchasers can still manage their subscription.
    assert not response.json()["available"]
    assert response.headers["cache-control"] == "private, no-store"


async def test_non_ascii_webhook_authorization_is_rejected(client, paid, monkeypatch):
    monkeypatch.setattr(settings, "revenuecat_webhook_secret", "Bearer secret")
    response = await client.post("/billing/webhook", content=b"{}", headers={b"Authorization": b"\xff"})
    assert response.status_code == 401


async def test_misconfigured_secret_never_leaks_through_public_sdk_fields(client, paid, monkeypatch):
    monkeypatch.setattr(settings, "revenuecat_apple_sdk_key", "sk_apple-secret")
    monkeypatch.setattr(settings, "revenuecat_google_sdk_key", "sk_google-secret")
    response = await client.get("/billing/status")
    assert response.json()["apple_sdk_key"] == ""
    assert response.json()["google_sdk_key"] == ""
    assert "sk_" not in response.text
