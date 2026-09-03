from __future__ import annotations

import hashlib
import json
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
                        "attributes": {"screenshotDisplayType": "APP_IPHONE_67"},
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
    locale = store.LocaleListing("en-GB", {}, {"APP_IPHONE_67": (screenshot,)})

    store.sync_screenshots(client, {"id": "localization-id"}, locale, dry_run=False)

    assert client.deleted == []
    assert client.patched == []


def test_dry_run_never_replaces_changed_screenshot_set(tmp_path: Path):
    screenshot = tmp_path / "01-latest.png"
    screenshot.write_bytes(b"new image")
    client = FakeScreenshotClient(screenshot.name, "old-checksum")
    locale = store.LocaleListing("en-GB", {}, {"APP_IPHONE_67": (screenshot,)})

    store.sync_screenshots(client, {"id": "localization-id"}, locale, dry_run=True)

    assert client.deleted == []
    assert client.patched == []


class FakeVersionClient:
    def __init__(self, *, build: dict | None = None):
        self.versions = [
            {
                "id": "draft-id",
                "attributes": {
                    "versionString": "1.0",
                    "appStoreState": "PREPARE_FOR_SUBMISSION",
                    "copyright": "2025 Example",
                    "releaseType": "MANUAL",
                },
            }
        ]
        self.build = build
        self.patches: list[tuple[str, dict]] = []

    def get(self, path: str, **_kwargs) -> dict:
        if path.endswith("/appStoreVersions"):
            return {"data": self.versions}
        if path.endswith("/build"):
            return {"data": self.build}
        raise AssertionError(path)

    def patch(self, path: str, body: dict) -> dict:
        self.patches.append((path, body))
        return {"data": self.versions[0]}


def test_empty_editable_version_is_retargeted_for_release():
    client = FakeVersionClient()

    result = store.ensure_version(client, "app-id", listing(), "1.3.0", dry_run=False)

    assert result is not None
    assert result["id"] == "draft-id"
    assert result["attributes"]["versionString"] == "1.3.0"
    assert client.patches[0][0] == "/appStoreVersions/draft-id"
    assert client.patches[0][1]["data"]["attributes"]["versionString"] == "1.3.0"


def test_dry_run_plans_retarget_without_writing():
    client = FakeVersionClient()

    result = store.ensure_version(client, "app-id", listing(), "1.3.0", dry_run=True)

    assert result is not None
    assert result["attributes"]["versionString"] == "1.3.0"
    assert client.patches == []


def test_version_with_selected_build_is_not_retargeted():
    client = FakeVersionClient(build={"id": "build-id", "type": "builds"})

    with pytest.raises(store.Failure, match="already has a selected build"):
        store.ensure_version(client, "app-id", listing(), "1.3.0", dry_run=False)

    assert client.patches == []


class FakeInFlightVersionClient(FakeVersionClient):
    """The app has 1.3.0 waiting for review and nothing editable, and Apple
    answers the attempt to create 1.4.0 with its unhelpful 409."""

    def __init__(self):
        super().__init__()
        self.versions = [
            {"id": "old-id", "attributes": {"versionString": "1.2.0", "appStoreState": "REPLACED_WITH_NEW_VERSION"}},
            {"id": "live-id", "attributes": {"versionString": "1.3.0", "appStoreState": "WAITING_FOR_REVIEW"}},
        ]

    def post(self, path: str, body: dict) -> dict:
        raise store.AppStoreConnectFailure(
            "POST",
            path,
            409,
            json.dumps(
                {
                    "errors": [
                        {
                            "status": "409",
                            "code": "ENTITY_ERROR.RELATIONSHIP.INVALID",
                            "detail": "You cannot create a new version of the App in the current state.",
                        }
                    ]
                }
            ),
        )


def test_refused_version_creation_names_the_version_in_flight():
    client = FakeInFlightVersionClient()

    with pytest.raises(store.Failure) as failure:
        store.ensure_version(client, "app-id", listing(), "1.4.0", dry_run=False)

    message = str(failure.value)
    assert "1.3.0 (WAITING_FOR_REVIEW)" in message
    assert "1.2.0" not in message
    assert "sync_version=1.4.0" in message


class FakeResponse:
    def __init__(self, status_code: int, body: dict | None = None):
        self.status_code = status_code
        self.ok = status_code < 400
        self.content = json.dumps(body).encode() if body is not None else b""
        self.text = self.content.decode()

    def json(self) -> dict:
        return json.loads(self.text)


class FakeSession:
    def __init__(self, responses: list[FakeResponse]):
        self.responses = list(responses)
        self.headers: dict[str, str] = {}
        self.calls: list[tuple[str, str, str]] = []

    def request(self, method: str, url: str, **_kwargs) -> FakeResponse:
        self.calls.append((method, url, self.headers["Authorization"]))
        return self.responses.pop(0)


def retrying_client(monkeypatch, responses: list[FakeResponse]) -> tuple[store.Client, FakeSession, list[float]]:
    tokens = iter(("first", "second", "third"))
    monkeypatch.setattr(store, "api_token", lambda: next(tokens))
    slept: list[float] = []
    session = FakeSession(responses)
    return store.Client(session, sleep=slept.append), session, slept


def test_a_passing_401_is_retried_with_a_fresh_token(monkeypatch):
    client, session, slept = retrying_client(monkeypatch, [FakeResponse(401), FakeResponse(200, {"data": []})])

    assert client.get("/apps") == {"data": []}
    assert [call[2] for call in session.calls] == ["Bearer first", "Bearer second"]
    assert slept == [store.RETRY_DELAY_SECONDS]


def test_a_persistent_failure_is_reported_after_the_last_attempt(monkeypatch):
    client, session, _ = retrying_client(monkeypatch, [FakeResponse(503)] * store.RETRY_ATTEMPTS)

    with pytest.raises(store.AppStoreConnectFailure, match="-> 503"):
        client.get("/apps")
    assert len(session.calls) == store.RETRY_ATTEMPTS


def test_a_post_that_may_have_landed_is_not_retried(monkeypatch):
    client, session, slept = retrying_client(monkeypatch, [FakeResponse(503), FakeResponse(201, {"data": {}})])

    with pytest.raises(store.AppStoreConnectFailure, match="-> 503"):
        client.post("/appStoreVersions", {})
    assert len(session.calls) == 1
    assert slept == []


class FakeFirstVersionLocalizationClient:
    def __init__(self):
        self.patches: list[dict] = []

    def get(self, path: str, **_kwargs) -> dict:
        if path.endswith("/appStoreVersionLocalizations"):
            return {
                "data": [
                    {
                        "id": "localization-id",
                        "attributes": {"locale": "en-GB"},
                    }
                ]
            }
        raise AssertionError(path)

    def patch(self, _path: str, body: dict) -> dict:
        attributes = body["data"]["attributes"]
        self.patches.append(attributes)
        if "whatsNew" in attributes:
            response = {
                "errors": [
                    {
                        "code": "STATE_ERROR",
                        "detail": "Attribute 'whatsNew' cannot be edited at this time",
                    }
                ]
            }
            raise store.AppStoreConnectFailure("PATCH", "/localization", 409, json.dumps(response))
        return {}


def test_first_public_version_syncs_without_unavailable_whats_new():
    client = FakeFirstVersionLocalizationClient()

    store.sync_version_localizations(
        client,
        {"id": "version-id"},
        listing(),
        "Release notes",
        dry_run=False,
    )

    assert client.patches[0]["whatsNew"] == "Release notes"
    assert "whatsNew" not in client.patches[1]
    assert client.patches[1]["description"] == "Description"
