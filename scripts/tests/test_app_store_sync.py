from __future__ import annotations

import hashlib
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import app_store_sync as store


def listing(*, description: str = "Description") -> store.Listing:
    fields = {
        "name": "Hearful",
        "subtitle": "Podcasts and articles by voice",
        "description": description,
        "keywords": "podcast,voice",
        "promotional_text": "Ask for something worth hearing.",
        "support_url": "https://example.com/support",
        "privacy_policy_url": "https://example.com/privacy",
    }
    return store.Listing(
        config={
            "bundleId": "com.example.hearful",
            "platform": "IOS",
            "primaryLocale": "en-GB",
            "copyright": "2026 Example",
            "releaseType": "MANUAL",
        },
        locales=(store.LocaleListing("en-GB", fields, {}),),
        review_notes="Review these steps.",
    )


def test_empty_screenshot_directories_are_safe_but_visible():
    warnings = store.validate_listing(listing())
    assert warnings == ["en-GB has no screenshots yet; remote screenshot sets will be left alone"]


def test_metadata_over_apples_limit_is_rejected():
    with pytest.raises(store.Failure, match="4001 characters"):
        store.validate_listing(listing(description="x" * 4_001))


class FakeScreenshotClient:
    def __init__(self, filename: str, checksum: str):
        self.filename = filename
        self.checksum = checksum
        self.deleted: list[str] = []
        self.patched: list[str] = []

    def get(self, path: str, **_kwargs) -> dict:
        if path.endswith("/appScreenshotSets"):
            return {
                "data": [
                    {
                        "id": "set-id",
                        "attributes": {"screenshotDisplayType": "APP_IPHONE_69"},
                    }
                ]
            }
        if path.endswith("/appScreenshots"):
            return {
                "data": [
                    {
                        "id": "image-id",
                        "attributes": {
                            "fileName": self.filename,
                            "sourceFileChecksum": self.checksum,
                        },
                    }
                ]
            }
        raise AssertionError(path)

    def delete(self, path: str) -> None:
        self.deleted.append(path)

    def patch(self, path: str, _body: dict) -> dict:
        self.patched.append(path)
        return {}


def test_matching_screenshot_set_is_not_replaced(tmp_path: Path):
    screenshot = tmp_path / "01-latest.png"
    screenshot.write_bytes(b"approved image")
    checksum = hashlib.md5(screenshot.read_bytes()).hexdigest()
    client = FakeScreenshotClient(screenshot.name, checksum)
    locale = store.LocaleListing("en-GB", {}, {"APP_IPHONE_69": (screenshot,)})

    store.sync_screenshots(client, {"id": "localization-id"}, locale, dry_run=False)

    assert client.deleted == []
    assert client.patched == []


def test_dry_run_never_replaces_changed_screenshot_set(tmp_path: Path):
    screenshot = tmp_path / "01-latest.png"
    screenshot.write_bytes(b"new image")
    client = FakeScreenshotClient(screenshot.name, "old-checksum")
    locale = store.LocaleListing("en-GB", {}, {"APP_IPHONE_69": (screenshot,)})

    store.sync_screenshots(client, {"id": "localization-id"}, locale, dry_run=True)

    assert client.deleted == []
    assert client.patched == []
