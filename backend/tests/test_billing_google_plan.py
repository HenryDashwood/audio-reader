"""RevenueCat v1 identifies Google subscriptions by product and base plan separately."""

from datetime import timedelta
from unittest.mock import AsyncMock

from audioreader import billing
from audioreader.config import settings
from audioreader.models import utcnow


async def test_google_monthly_purchase_uses_verified_base_plan(client, monkeypatch):
    monkeypatch.setattr(settings, "billing_enabled", True)
    monkeypatch.setattr(settings, "revenuecat_api_key", "test-secret")
    monkeypatch.setattr(settings, "datalab_api_key", "test-secret")
    monkeypatch.setattr(settings, "pdf_import_enabled", True)
    monkeypatch.setattr(settings, "environment", "staging")
    monkeypatch.setattr(settings, "revenuecat_products", ("magpie_plus_monthly", "magpie_plus:monthly"))

    now = utcnow()
    expires = (now + timedelta(minutes=5)).isoformat()
    subscriber = {
        "entitlements": {"magpie_plus": {"product_identifier": "magpie_plus", "expires_date": expires}},
        "subscriptions": {
            "magpie_plus": {
                "store": "play_store",
                "product_plan_identifier": "monthly",
                "is_sandbox": True,
                "purchase_date": (now - timedelta(seconds=5)).isoformat(),
                "expires_date": expires,
            }
        },
    }
    monkeypatch.setattr(billing, "fetch_subscriber", AsyncMock(return_value=subscriber))

    monthly = (await client.post("/billing/sync")).json()
    assert monthly["active"] and monthly["remaining_pages"] == 500
    assert monthly["store"] == "play_store"

    subscriber["subscriptions"]["magpie_plus"]["product_plan_identifier"] = "annual"
    assert not (await client.post("/billing/sync")).json()["active"]
    del subscriber["subscriptions"]["magpie_plus"]["product_plan_identifier"]
    assert not (await client.post("/billing/sync")).json()["active"]
