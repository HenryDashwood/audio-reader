"""Server-verified RevenueCat access and durable, account-wide PDF allowances."""

from datetime import UTC, datetime, timedelta
from urllib.parse import quote

import httpx
from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from audioreader.config import settings
from audioreader.models import BillingCustomer, PDFPageUsage, User, UserIdentity, utcnow


def configured() -> bool:
    return bool(settings.billing_enabled and settings.revenuecat_api_key)


def purchases_available() -> bool:
    return bool(configured() and settings.pdf_import_enabled and settings.datalab_api_key)


def aware(value: datetime) -> datetime:
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value


async def verified_email(session: AsyncSession, user: User, emails: tuple[str, ...]) -> bool:
    return bool(
        await session.scalar(
            select(UserIdentity.id)
            .where(
                UserIdentity.user_id == user.id,
                UserIdentity.provider.in_(["google", "apple"]),
                func.lower(UserIdentity.email).in_([email.lower() for email in emails]),
            )
            .limit(1)
        )
    )


async def unlimited(session: AsyncSession, user: User) -> bool:
    return await verified_email(session, user, settings.pdf_import_emails)


async def customers(session: AsyncSession, user: User) -> list[BillingCustomer]:
    rows = list(
        await session.scalars(
            select(BillingCustomer)
            .where(BillingCustomer.user_id == user.id)
            .order_by(BillingCustomer.created_at, BillingCustomer.id)
        )
    )
    if not rows:
        # All creators lock the account first; IDs contain no email or profile data.
        row = BillingCustomer(id=f"magpie_{settings.environment}_{user.id.hex}", user_id=user.id)
        session.add(row)
        await session.flush()
        rows.append(row)
    return rows


async def fetch_subscriber(customer_id: str) -> dict:
    try:
        async with httpx.AsyncClient(timeout=12, trust_env=False) as client:
            response = await client.get(
                f"https://api.revenuecat.com/v1/subscribers/{quote(customer_id, safe='')}",
                headers={"Authorization": f"Bearer {settings.revenuecat_api_key}"},
            )
            response.raise_for_status()
            payload = response.json()
            if not isinstance(payload.get("subscriber"), dict):
                raise ValueError("Invalid subscriber response")
            return payload["subscriber"]
    except (httpx.HTTPError, ValueError):
        raise HTTPException(503, "Subscription status is temporarily unavailable. Please try again.") from None


def date(value: object) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        return aware(datetime.fromisoformat(value.replace("Z", "+00:00")))
    except ValueError:
        return None


def apply_subscriber(row: BillingCustomer, subscriber: dict, *, sandbox_allowed: bool) -> None:
    """Only the configured monthly product can grant a page allowance."""
    entitlement = subscriber.get("entitlements", {}).get(settings.revenuecat_entitlement) or {}
    product = entitlement.get("product_identifier")
    subscription = subscriber.get("subscriptions", {}).get(product) or {}
    start = date(subscription.get("purchase_date"))
    end = date(subscription.get("expires_date"))
    access = date(entitlement.get("expires_date"))
    grace = date(subscription.get("grace_period_expires_date"))
    valid = (
        product in settings.revenuecat_products
        and subscription.get("store") in {"app_store", "play_store"}
        and not subscription.get("refunded_at")
        and (subscription.get("is_sandbox") is False or sandbox_allowed)
        and start is not None
        and end is not None
        and access is not None
        and start <= utcnow()
        and start < end
        and end - start <= timedelta(days=35)
    )
    row.product_id = product if valid else None
    row.store = subscription.get("store") if valid else None
    row.period_start = start if valid else None
    row.period_end = end if valid else None
    row.access_until = max(access, grace or access) if valid and access else None
    row.checked_at = utcnow()


async def current(
    session: AsyncSession, user: User, *, refresh: bool = False
) -> tuple[list[BillingCustomer], BillingCustomer | None]:
    # A single lock order is shared by imports, account merges, and webhook refreshes.
    await session.execute(select(User.id).where(User.id == user.id).with_for_update())
    rows = await customers(session, user)
    if not configured():
        return rows, None
    sandbox = settings.environment != "production" or await verified_email(
        session, user, settings.billing_sandbox_emails
    )
    for row in rows:
        if (
            refresh
            or row.checked_at is None
            or aware(row.checked_at) < utcnow() - timedelta(minutes=5)
            or (row.access_until is not None and aware(row.access_until) <= utcnow())
        ):
            apply_subscriber(row, await fetch_subscriber(row.id), sandbox_allowed=sandbox)
    active = [row for row in rows if row.access_until and aware(row.access_until) > utcnow()]
    return rows, max(active, key=lambda row: aware(row.period_end or row.access_until or utcnow())) if active else None


async def used_pages(session: AsyncSession, user: User, row: BillingCustomer) -> int:
    return int(
        await session.scalar(
            select(func.coalesce(func.sum(PDFPageUsage.pages), 0)).where(
                PDFPageUsage.user_id == user.id,
                PDFPageUsage.state != "released",
                PDFPageUsage.created_at >= row.period_start,
                PDFPageUsage.created_at < row.access_until,
            )
        )
        or 0
    )


async def status(session: AsyncSession, user: User, *, refresh: bool = False) -> dict:
    owner = await unlimited(session, user)
    rows, active = await current(session, user, refresh=refresh)
    used = await used_pages(session, user, active) if active else 0
    result = {
        "available": purchases_available(),
        "active": bool(active),
        "unlimited": owner,
        "customer_id": rows[0].id,
        "apple_sdk_key": settings.revenuecat_apple_sdk_key
        if configured() and settings.revenuecat_apple_sdk_key.startswith("appl_")
        else "",
        "google_sdk_key": settings.revenuecat_google_sdk_key
        if configured() and settings.revenuecat_google_sdk_key.startswith("goog_")
        else "",
        "entitlement_id": settings.revenuecat_entitlement,
        "offering_id": settings.revenuecat_offering,
        "monthly_pages": settings.plus_monthly_pages,
        "used_pages": used,
        "remaining_pages": None if owner else max(0, settings.plus_monthly_pages - used) if active else 0,
        "period_end": active.period_end if active else None,
        "store": active.store if active else None,
    }
    await session.commit()
    return result


async def has_access(session: AsyncSession, user: User) -> bool:
    if await unlimited(session, user):
        return True
    if not configured():
        return False
    _, active = await current(session, user)
    return active is not None


async def reserve(session: AsyncSession, user: User, document_id: str, pages: int) -> None:
    if await unlimited(session, user):
        return
    _, active = await current(session, user)
    if active is None:
        raise HTTPException(
            403, "Magpie Plus is required to import PDFs. Subscribe or restore purchases in Magpie Settings."
        )
    existing = await session.get(PDFPageUsage, document_id)
    if existing and existing.state != "released":
        return
    remaining = max(0, settings.plus_monthly_pages - await used_pages(session, user, active))
    if pages > remaining:
        raise HTTPException(
            409,
            f"This PDF has {pages} pages, but you have {remaining} pages left. "
            f"Your allowance renews on {active.period_end:%d %B}.",
        )
    if existing is None:
        existing = PDFPageUsage(document_id=document_id, user_id=user.id)
        session.add(existing)
    existing.pages = pages
    existing.state = "reserved"
    assert active.period_start is not None and active.period_end is not None
    existing.period_start = active.period_start
    existing.period_end = active.period_end
    existing.created_at = utcnow()
    await session.flush()
